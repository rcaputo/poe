# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Attribute::Scalar;
use strict;
use POSIX qw(errno_h);

sub DEB_TIE () { 0 }

sub TS_REPOSITORY () { 0 }
sub TS_ATTRIBUTE  () { 1 }
sub TS_WRITE_ID   () { 2 }
sub TS_READ_ID    () { 3 }

sub TIESCALAR {
  my ($package, $repository, $attribute, $write_id, $read_id) = @_;
  my $self = bless [ $repository, $attribute, $write_id, $read_id
                   ], $package;
  $self;
}

sub FETCH {
  my $self = shift;
  my ($status, $value) =
    $self->[TS_REPOSITORY]->attribute_fetch( $self->[TS_READ_ID],
                                             $self->[TS_ATTRIBUTE]
                                           );
  if ($status) {
    $! = $status;
    return undef;
  }
  $! = 0;
  return $value;
}

sub STORE {
  my $self = shift;
}

sub DESTROY {
  my $self = shift;
}

###############################################################################
1;
