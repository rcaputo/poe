# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Attribute::Array;
use strict;
use POSIX qw(errno_h);

sub DEB_TIE () { 0 }

sub TA_REPOSITORY () { 0 }
sub TA_ATTRIBUTE  () { 1 }
sub TA_READ_ID    () { 2 }
sub TA_WRITE_ID   () { 3 }

#------------------------------------------------------------------------------

sub TIEARRAY {
  my ($package, $repository, $attribute, $read_id, $write_id) = @_;
  my $self = bless [ $repository, $attribute, $read_id, $write_id], $package;
  $self;
}

#------------------------------------------------------------------------------

sub FETCH {
  my ($self, $index) = @_;

  my ($status, $value) =
    $self->[TA_REPOSITORY]->attribute_fetch( $self->[TA_READ_ID],
                                             $self->[TA_ATTRIBUTE]
                                           );
  if ($status) {
    $! = $status;
    return undef;
  }

  if (ref($value) ne 'ARRAY') {
    $! = EINVAL;
    return undef;
  }

  if (abs($index) >= @$value) {
    $! = EDOM;
    return undef;
  }

  $! = 0;
  return $value->[$index];
}

#------------------------------------------------------------------------------

sub FETCHSIZE {
  my ($self) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub STORE {
  my ($self, $index, $value) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub STORESIZE {
  my ($self, $count) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub CLEAR {
  my ($self) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub PUSH {
  my ($self, @list) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub POP {
  my ($self) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub SHIFT {
  my ($self) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub UNSHIFT {
  my ($self, @list) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub SPLICE {
  my ($self, $offset, $length, @list) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub EXTEND {
  my ($self, $new_size) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my ($self) = @_;
  $! = ENOSYS;
  return undef;
}

###############################################################################
1;
