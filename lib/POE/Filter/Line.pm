# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::Line;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'framing buffer' => '' }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  $self->{'framing buffer'} .= join('', @$stream);
  my @result;
  while (
         $self->{'framing buffer'} =~ s/^([^\x0D\x0A]*)(\x0D\x0A?|\x0A\x0D?)//
  ) {
    push(@result, $1);
  }
  \@result;
}

#------------------------------------------------------------------------------

sub put {
  my $self = shift;
  my $raw = join("\x0D\x0A", @_) . "\x0D\x0A";
}

###############################################################################
1;
