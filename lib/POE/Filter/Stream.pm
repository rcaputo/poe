# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::Stream;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $t='';
  my $self = bless \$t, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my $buffer = join('', @$stream);
  [ $buffer ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  $chunks;
}

#------------------------------------------------------------------------------

sub get_pending {} #we don't keep any state

###############################################################################
1;
