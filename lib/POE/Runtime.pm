# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Runtime;

use strict;

use POE::Session;

*spawn = \&POE::Object::spawn;
*object = \&POE::Curator::object;
*post = \&POE::Object::post;

#------------------------------------------------------------------------------
