# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Repository::Array;

use strict;
use POSIX qw(errno_h);

#------------------------------------------------------------------------------
# Create a repository.
#
# my $repository = new POE::Repository::Array(\@objects);
#
# @objects is an array of hash references.  Each referenced hash
# contains attribute values, keyed on the attributes' names.
#
# Returns an object with a standard interface.

sub new {
  my ($package, $arrayref, @flags) = @_;
  my $self = bless $arrayref, $package;
  $self;
}

#------------------------------------------------------------------------------
# Test the validity of an object ID.
#
# my $status = $repository->test_object($object_id);
#
# Returns EINVAL if the ID is malformed.
# Returns ENOENT if the ID refers to a nonexistent object.
# Returns 0 if the object ID is good.

sub object_test {
  my ($self, $id) = @_;

  return EINVAL
    unless (defined($id) && ($id =~ /^\d+$/));

  return ENOENT
    unless ( ($id >= 0) &&
             ($id < scalar(@$self)) &&
             (defined $self->[$id])
           );

  return 0;
}

#------------------------------------------------------------------------------
# Fetch an attribute from an object.
#
# my ($status, $value) =
#   $repository->fetch_attribute($object_id, $attribute_name);
#
# Returns (EINVAL, undef) or (ENOENT, undef) if &test_object fails.
# Returns (ENOSYS, undef) if the attribute doesn't exist.
# Returns (0, $value) if the attribute can be fetched.

sub attribute_fetch {
  my ($self, $id, $attribute) = @_;

  my $status = $self->object_test($id);
  return ($status, undef) if ($status);

  return (0, $self->[$id]->{$attribute})
    if (exists $self->[$id]->{$attribute});

  return (ENOSYS, undef);
}

#------------------------------------------------------------------------------
# Store an attribute into an object.  The object must exist.
#
# my ($status, $value) =
#   $repository->store_attribute($object_id, $attribute_name, $value);
#
# Returns (EINVAL, undef) or (ENOENT, undef) if &object_test fails.
# Returns (ENOSYS, undef) if the attribute doesn't exist.
# Returns (0, $value) if the value is stored.

sub attribute_store {
  my ($self, $id, $attribute, $value) = @_;

  my $status = $self->object_test($id);
  return ($status, undef) if ($status);

  $self->[$id]->{$attribute} = $value;

  return (0, $self->[$id]->{$attribute});
}

#------------------------------------------------------------------------------
# Compile an attribute.
#
# ($status, $retval) = $repository->attribute_compile($id, $att_name, $code);
#
# Returns (0, $coderef) on success.
# Returns (ENOEXEC, \@errors) on failure.

my $method_preamble  = 'package POE::Runtime; sub { ';
my $method_postamble = ' };';

sub attribute_compile {
  my ($self, $id, $attribute, $code) = @_;
  my @errors;

  # -><- code cache here

  $code =~ s/\s+\n/\n/gs;
  $code =~ s/(^|\n)\s+/ /sg;

  my $full_method = $method_preamble . $code . $method_postamble;
  my $coderef = eval($full_method);

  if ($@) {
    push @errors, $@;
    return (ENOEXEC, \@errors);
  }

  return (0, $coderef);
}

#------------------------------------------------------------------------------
# Create a new, empty object.
#
# my ($status, $object_id) = $repository->create_object( -><- );
#
# Returns (0, $object_id) if the object was created.

sub object_create {
  my ($self) = @_;

  push @$self, {};
  return $#$self;
}

#------------------------------------------------------------------------------
# Find all the objects with matching attributes.

sub objects_find {
  my ($self, $attribute, $value) = @_;
  my @found;

  for (my $id=0; $id<scalar(@$self); $id++) {
    next unless (defined(my $object = $self->[$id]));
    push(@found, $id) if ($object->{$attribute} eq $value);
  }

  \@found;
}

###############################################################################
1;
