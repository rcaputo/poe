# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::TiedObject;

use strict;
use POSIX qw(errno_h);

sub DEB_TIED_OBJ () { 0 }

sub TO_ID        () { 0 }
sub TO_CURATOR   () { 1 }

sub CS_ID        () { 0 } # -><- same as POE::Curator::CS_ID

#------------------------------------------------------------------------------
# Helper.  Snatch the error code from the trap frame.

sub _fetch_other_parameters {
  my $heap = do {
    package DB;
    # @BD::args isn't populated without the assign to @x :(
    my @x = caller(2);
    $DB::args[POE::Session::HEAP];
  };
  my $caller = $heap->{call_stack};
  ($heap, ((@$caller) ? $caller->[-1]->[CS_ID] : undef));
}

#------------------------------------------------------------------------------
# Tie myself to myself.  Autoneurotic bondage?

sub TIEHASH {
  my ($package, $curator, $id) = @_;
  my $self = bless [ $id, $curator ], $package;
  $self;
}

#------------------------------------------------------------------------------

sub STORE {
  my ($self, $key, $value) = @_;

  if ($key eq 'id') {
    $! = EPERM;
    return $self->[TO_ID];
  }
  if ($key eq 'curator') {
    $! = EPERM;
    return $self->[TO_CURATOR];
  }

  my ($heap, $caller) = _fetch_other_parameters();

  DEB_TIED_OBJ &&
    print( "%%% STORE: heap($heap) caller($caller) id($self->[TO_ID]) ",
           "key($key) val($value) ref(", ref($value), ")\n"
         );

  ($!, $value) = $self->[TO_CURATOR]->attribute_store
    ($heap, $caller, $self->[TO_ID], $key, $value);

  DEB_TIED_OBJ && $! &&
    print "%%% STORE: failed: $!\n";

  $value;
}

#------------------------------------------------------------------------------

sub FETCH {
  my ($self, $key) = @_;

  $! = 0;
  return ($self->[TO_ID]) if ($key eq 'id');
  return ($self->[TO_CURATOR]) if ($key eq 'curator');

  my ($heap, $caller) = _fetch_other_parameters();

  my ($status, $value) = $self->[TO_CURATOR]->attribute_fetch
    ($heap, $caller, $self->[TO_ID], $key);

  DEB_TIED_OBJ &&
    print( "%%% FETCH: heap($heap) caller($caller) id($self->[TO_ID]) ",
           "key($key) status($status) value(",
           ((defined $value) ? $value : '<<undef>>'), ") ref(",
           ref($value), ")\n"
         );

  if ($status == ENOSYS) {
    $! = 0;
    return '';
  }

  $! = $status;

  DEB_TIED_OBJ && $! &&
    print "%%% FETCH: failed: $!\n";

  return $value;
}

#------------------------------------------------------------------------------

sub FIRSTKEY {
  my ($self) = @_;

  die "-><- not implemented";

  # my $a = keys %$self;
  # each %$self;
}

#------------------------------------------------------------------------------

sub NEXTKEY {
  my ($self, $lastkey) = @_;

  die "-><- not implemented";

  #each %$self;
}

#------------------------------------------------------------------------------

sub EXISTS {
  my ($self, $key) = @_;

  die "-><- not implemented";

  # my $exists = POE::Curator::exists($caller, $$self, $key);
  # DEB_TIED_OBJ && print "%%% EXISTS: key($key) = $exists\n";
  # $exists;
}

###############################################################################

package POE::Object;

use strict;
use POSIX qw(errno_h);
use Carp;
use POE;
use POE::Curator;

sub DEB_EVENT  () { 0 }
sub DEB_OBJECT () { 0 }

#------------------------------------------------------------------------------
# Helper.  Snatch the error code from the trap frame.

sub _fetch_actor {
  my $heap = do {
    package DB;
    # @BD::args isn't populated without the assign to @x :(
    my @x = caller(2);
    $DB::args[POE::Session::HEAP];
  };
  my $caller = $heap->{call_stack};
  $caller;
}

#------------------------------------------------------------------------------
# Create a new wrapper around a database object.

sub new {
  my ($package, $curator, $id) = @_;

  tie my (%self), 'POE::TiedObject', $curator, $id;
  my $self = bless \%self, $package;

  DEB_OBJECT &&
    print( "))) $self -> new: curator($curator) id(",
           ((defined $id) ? $id : '<<undef>>'), ")\n"
         );
  $self;
}

#------------------------------------------------------------------------------
# Post to a method within the same session.

sub post {
  my ($self, $method, $args) = @_;
  my $actor = $self->_fetch_actor();

  (defined $args) || ($args = []);
  DEB_OBJECT && print "))) $self -> post: method($method) args(@$args)\n";

  $poe_kernel->yield('curator_post', $actor, $self->{id}, $method, $args);
}

#------------------------------------------------------------------------------
# Post to a method, but in a new session.

sub spawn {
  my ($self, $method, @args) = @_;
  my $actor = $self->_fetch_actor();

  DEB_OBJECT && print "))) $self -> spawn: method($method) args(@args)\n";

  new POE::Session
    ( _start => sub {
        DEB_EVENT && print "### ", $_[SESSION], " -> _start\n";
        $_[HEAP]->{call_stack} = [];
        $_[KERNEL]->yield
          ('curator_post', $actor, $self->{id}, $method, \@args);
      },
      _stop => sub {
        DEB_EVENT && print "### ", $_[SESSION], " -> stop\n";
      },
      'curator_post' => sub {
        DEB_EVENT && print "### ", $_[SESSION], " -> curator_post\n";
        my ($heap, $actor, $object, $method, $args) =
          @_[HEAP, ARG0, ARG1, ARG2, ARG3];
        (defined $args) || ($args = []);
        $self->{curator}->attribute_execute
          ($heap, $actor, $self->{id}, $method, $args);
      },
    );
}

#------------------------------------------------------------------------------
# Delete an object from the database.  Nasty nasty.

sub delete {
  my ($self) = @_;
  DEB_OBJECT && print "))) $self -> delete\n";
}

#------------------------------------------------------------------------------
# Destroy this object wrapper.

sub DESTROY {
  my $self = shift;
  DEB_OBJECT && print "))) $self -> DESTROY\n";
  untie %$self;
}

###############################################################################
1;
