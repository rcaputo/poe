# $Id$

# Filter::Reference partial copyright 1998 Artur Bergman
# <artur@vogon-solutions.com>.  Partial copyright 1999 Philip Gwyn.

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::Reference;

use strict;
use Carp;

#------------------------------------------------------------------------------
# Try to require one of the default freeze/thaw packages.

sub _default_freezer
{
  local $SIG{'__DIE__'} = 'DEFAULT';
  my $ret;

  foreach my $p (qw(Storable FreezeThaw)) {
    eval { require "$p.pm"; import $p ();};
    warn $@ if $@;
    return $p if $@ eq '';
  }
  die "Filter::Reference requires Storable or FreezeThaw";
}

#------------------------------------------------------------------------------

sub new 
{
  my($type, $freezer) = @_;
  $freezer||=_default_freezer();
                                        # not a reference... maybe a package?
    unless(ref $freezer) {
      unless(exists $::{$freezer.'::'}) {
        eval {require "$freezer.pm"; import $freezer ();};
        croak $@ if $@;
      }
    }

  # Now get the methodes we want
  my $freeze=$freezer->can('freeze') || $freezer->can('nfreeze');
  carp "$freezer doesn't have a freeze method" unless $freeze;
  my $thaw=$freezer->can('thaw');
  carp "$freezer doesn't have a thaw method" unless $thaw;


  # If it's an object, we use closures to create a $self->method()
  my $tf=$freeze;
  my $tt=$thaw;
  if(ref $freezer) {
    $tf=sub {$freeze->($freezer, @_)};
    $tt=sub {$thaw->($freezer, @_)};
  }
  my $self = bless { 'framing buffer' => '',
                     'expecting' => 0,
                     'thaw'=>$tt, 'freeze'=>$tf,
                   }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my @return;

  $self->{'framing buffer'} .= join('', @$stream);

  # This doesn't allow 0-byte messages.  That's not a problem for
  # passing frozen references, but it may cause trouble for filters
  # derived from this code.  Modify according to taste.

  while ($self->{'expecting'} ||
         ( ($self->{'framing buffer'} =~ s/^(\d+)\0//s) &&
           ($self->{'expecting'} = $1)
         )
  ) {
    last unless ($self->{'framing buffer'} =~ s/^(.{$self->{'expecting'}})//s);
    push @return, $self->{thaw}->($1);
    $self->{'expecting'} = 0;
  }

  return \@return;
}

#------------------------------------------------------------------------------
# freeze one or more references, and return a string representing them

sub put {
  my ($self, $references) = @_;
  my @raw = map {
    my $frozen = $self->{freeze}->($_);
    length($frozen) . "\0" . $frozen;
  } @$references;
  \@raw;
}

###############################################################################
1;
