# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Runtime;

use strict;
use Carp;

use POE::Session;
use POE::Curator;
use POE::Object;

sub ACTOR  () { POE::Session::SENDER }
sub METHOD () { POE::Session::STATE  }
sub ME     () { POE::Session::OBJECT }

my %aspects;

sub initialize {
  my ($package, @parameters) = @_;
  my %parameters = @parameters;

  croak "Runtime must be initialized with a Curator"
    unless (exists $parameters{Curator});

  %aspects = %parameters;
}

sub object {
  $aspects{Curator}->object(@_);
}

###############################################################################
1;
