# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Attribute::Hash;
use strict;
use POSIX qw(errno_h);

sub DEB_TIE () { 0 }

sub TH_REPOSITORY () { 0 }
sub TH_ATTRIBUTE  () { 1 }
sub TH_READ_ID    () { 2 }
sub TH_WRITE_ID   () { 3 }
sub TH_KEYS       () { 4 }

#------------------------------------------------------------------------------

sub TIEHASH {
  my ($package, $repository, $attribute, $read_id, $write_id) = @_;
  my $self = bless [ $repository, $attribute, $read_id, $write_id ], $package;
  $self;
}

#------------------------------------------------------------------------------

sub FETCH {
  my ($self, $key) = @_;

  my ($status, $att_value) =
    $self->[TH_REPOSITORY]->attribute_fetch( $self->[TH_READ_ID],
                                             $self->[TH_ATTRIBUTE]
                                           );
  if ($status) {
    $! = $status;
    return undef;
  }

  if (ref($att_value) ne 'HASH') {
    $! = EINVAL;
    return undef;
  }

  $! = 0;
  return $att_value->{$key};
}

#------------------------------------------------------------------------------
# To do: Test _can_add and _did_add side-effects.

sub STORE {
  my ($self, $key, $value) = @_;

  my ($status, $att_value) =
    $self->[TH_REPOSITORY]->attribute_fetch( $self->[TH_READ_ID],
                                             $self->[TH_ATTRIBUTE]
                                           );
  if ($status) {
    $! = $status;
    return undef;
  }

  if (ref($att_value) ne 'HASH') {
    $! = EINVAL;
    return undef;
  }

  # -><- Test _can_add here.

  $! = 0;
  return $att_value->{$key} = $value;
}

#------------------------------------------------------------------------------
# To simulate some level of atomicity, we iterate here over a copy of
# the hash's keys.

sub FIRSTKEY {
  my ($self) = @_;

  my ($status, $value) = 
    $self->[TH_REPOSITORY]->attribute_fetch( $self->[TH_READ_ID],
                                             $self->[TH_ATTRIBUTE]
                                           );
  if ($status) {
    $! = $status;
    return undef;
  }

  if (ref($value) ne 'HASH') {
    $! = EINVAL;
    return undef;
  }

  $self->[TH_KEYS] = [ keys %$value ];
  my $next_key = shift @{$self->[TH_KEYS]};
  if (defined $next_key) {
    return $next_key;
  }
  return undef;
}

sub NEXTKEY {
  my ($self, $lastkey) = @_;

  my $next_key = shift @{$self->[TH_KEYS]};
  unless (defined $next_key) {
    return ();
  }

  my ($status, $value) = 
    $self->[TH_REPOSITORY]->attribute_fetch( $self->[TH_READ_ID],
                                             $self->[TH_ATTRIBUTE]
                                           );
  if ($status) {
    $! = $status;
    return undef;
  }

  if (ref($value) ne 'HASH') {
    $! = EINVAL;
    return undef;
  }

  return $next_key;
}

#------------------------------------------------------------------------------

sub EXISTS {
  my ($self, $key) = @_;
  $! = ENOSYS;
  return undef;
}

#------------------------------------------------------------------------------

sub DELETE {
  my ($self, $key) = @_;
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

sub DESTROY {
  my ($self) = @_;
  $! = ENOSYS;
  return undef;
}

###############################################################################
1;
