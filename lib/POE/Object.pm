# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Object;

use strict;
use POSIX qw(errno_h);
use Carp;
use POE;

sub DEB_EVENT  () { 0 }
sub DEB_OBJECT () { 0 }

#------------------------------------------------------------------------------
# Create a new wrapper around a database object.

sub new {
  my ($package, $id) = @_;
  my $self = bless { id => $id }, $package;
  DEB_OBJECT && print "))) $self -> new: id($id)\n";
  $self;
}

#------------------------------------------------------------------------------
# Post to a method within the same session.

sub post {
  my ($self, $method, $args) = @_;

  (defined $args) || ($args = []);

  DEB_OBJECT && print "))) $self -> post: method($method) args(@$args)\n";

  $poe_kernel->yield('curator_post', $self, $method, $args);
}

#------------------------------------------------------------------------------
# Fetch an attribute from the Curator.

sub fetch {
  my ($self, $method) = @_;
  POE::Curator::att_fetch($self->{id}, $method);
}

#------------------------------------------------------------------------------
# Execute a database object method.

my $method_preamble  = 'package POE::Runtime; sub { ';
my $method_postamble = ' };';

sub execute {
  my ($self, $heap, $method, $args) = @_;

  my ($status, $code) = POE::Curator::att_fetch($self->{id}, $method);

  if (defined $code) {
    my $full_method = $method_preamble . $code . $method_postamble;
    my $compiled_method = eval $full_method;
    &$compiled_method($self, undef, undef, $heap, $method, -1, @$args);
  }
  else {
    warn "$self -> execute failed: $!";
  }
}

#------------------------------------------------------------------------------
# Post to a method, but in a new session.

sub spawn {
  my ($self, $method, @args) = @_;
  DEB_OBJECT && print "))) $self -> spawn: method($method) args(@args)\n";

  new POE::Session
    ( _start => sub {
        DEB_EVENT && print "### ", $_[SESSION], " -> _start\n";
        $_[KERNEL]->yield('curator_post', $self, $method, \@args);
      },
      _stop => sub {
        DEB_EVENT && print "### ", $_[SESSION], " -> stop\n";
      },
      'curator_post' => sub {
        DEB_EVENT && print "### ", $_[SESSION], " -> curator_post\n";
        my ($object, $method, $args) = @_[ARG0, ARG1, ARG2];
        (defined $args) || ($args = []);
        $object->execute($_[HEAP], $method, $args);
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
}

###############################################################################
1;
