# $Id$

# Filter::Reference partial copyright 1998 Artur Bergman
# <artur@vogon-solutions.com>.

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::Reference;

use strict;

BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';
  eval {
    require Storable;
    import Storable qw(nfreeze thaw);
    *freeze = *nfreeze;
  };
  if ($@ ne '') {
    eval {
      require FreezeThaw;
      import FreezeThaw qw(freeze thaw);
    };
  }
  if ($@ ne '') {
    die "Filter::Reference requires Storable or FreezeThaw";
  }
}

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'framing buffer' => '',
                     'expecting' => 0
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
    push @return, thaw($1);
    $self->{'expecting'} = 0;
  }

  return \@return;
}

#------------------------------------------------------------------------------
# freeze one or more references, and return a string representing them

sub put {
  my $self = shift;
  my $return = '';
  foreach my $raw (@_) {
    my $frozen = freeze($raw);
    $return .= length($frozen) . "\0" . $frozen;
  }
  $return;
}

###############################################################################
1;
