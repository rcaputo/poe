# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Driver;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

#------------------------------------------------------------------------------
1;
