# $Id$

# Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights
# reserved.  This program is free software; you can redistribute it
# and/or modify it under the same terms as Perl itself.

package POE::Filter::Stream;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { }, $type;
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
  my $self = shift;
  my $raw = join('', @_);
}

###############################################################################
1;
