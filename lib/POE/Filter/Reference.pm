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
    import Storable qw(freeze thaw);
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
  my $self = bless { 'framing buffer' => '' }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my $string .= join('', @$stream);
  my @return;
  
  my $data;
  my $i = 1;
  if(exists($self->{'pre_get'})) {
    $string =~s/\A(.{$self->{'pre_get'}})//s;
    my $ick = $self->{pre_got}.$1;
    push @return,thaw($ick);
    delete($self->{'pre_get'});
    delete($self->{'pre_got'});
  }
  while($string ne "") {
    die "LOOP EXISTS:" if($i++ == 500);
    $string =~s/\A(\d+)\0//;
    my $bytes_to_get = $1;
    if(length($string) < $bytes_to_get) {
      $self->{'pre_get'} = $bytes_to_get - length($string);
      $bytes_to_get = length($string);
      $string =~s/\A(.{$bytes_to_get})//s;
      $self->{'pre_got'} = $1;
      last;
    } else {
      $string =~s/\A(.{$bytes_to_get})//s;
      my $data = $1;
      push @return,thaw($data);
    }
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
