# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::Line;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $t='';
  my $self = bless \$t, $type;      # we now use a scalar ref -PG
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  $$self .= join('', @$stream);
  my @result;
  while (
         $$self =~ s/^([^\x0D\x0A]*)(\x0D\x0A?|\x0A\x0D?)//
  ) {
    push(@result, $1);
  }
  \@result;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $lines) = @_;
  my @raw = map { $_ . "\x0D\x0A" } @$lines;
  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending 
{
    my($self)=@_;
    return unless $$self;
    my $ret=[$$self];
    $$self='';
    return $ret;
}

###############################################################################
1;
