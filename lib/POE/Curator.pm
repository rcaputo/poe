# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Curator;

use strict;
use POSIX qw(errno_h);
use Carp;

use POE::Object;
#use POE::Attribute::Scalar;
use POE::Attribute::Hash;
use POE::Attribute::Array;

#==============================================================================
# Private helpers.

sub CANFETCH () { '_can_fetch' }
sub DIDFETCH () { '_did_fetch' }
sub CANSTORE () { '_can_store' }
sub DIDSTORE () { '_did_store' }

sub CU_REPOSITORY () { 0 }

sub CS_ID  () { 0 }
sub CS_ATT () { 1 }

sub DEB_CURATOR () { 0 }

#------------------------------------------------------------------------------
# Create a curator to manage a repository.
#
# my $curator = new POE::Curator( Repository => $repository );

sub new {
  my ($package, %param) = @_;
  my $self = bless [], $package;

  croak "Repository is a required parameter"
    unless (exists $param{Repository});

  $self->[CU_REPOSITORY] = delete $param{Repository};

  my @bad_parameters = sort(keys(%param));
  while (my $bad_param = shift(@bad_parameters)) {
    if (@bad_parameters) {
      carp "Unknown parameter '$bad_param'";
    }
    else {
      croak "Unknown parameter '$bad_param'";
    }
  }

  $self;
}

#------------------------------------------------------------------------------
# Find an object attribute, walking backwards through the inheritance
# chain.
#
# ($status, $id, $value) =
#   $c->find_attribute_backwards($repository, $id, $attribute);
#
# Returns (EINVAL, undef, undef) if the parent chain is broken.
# Returns (ENOSYS, undef, undef) if the attribute doesn't exist.
# Returns (0, $id, $value) on success.

sub find_attribute_backwards {
  my ($self, $repository, $id, $attribute) = @_;
  my ($status, $value, %checked);

  while ('true') {
    ($status, $value) = $repository->attribute_fetch($id, $attribute);
    return (0, $id, $value) unless ($status);
    return ($status, undef, undef) if ($status == EINVAL);

    ($status, $id) = $repository->attribute_fetch($id, 'parent');
    return ($status, undef, undef) if ($status);
  }
}

#------------------------------------------------------------------------------
# Fetch an attribute, with side effects.
#
# ($status, $value) = $c->attribute_fetch($heap, $actor, $id, $attribute);
#
# Returns (EINVAL, undef) or (ENOENT, undef) if the repository doesn't
#         like the object ID.
# Returns (ENOSYS, undef) if the attribute doesn't exist.
# Returns (EPERM, undef) if the attribute may not be fetched.
# Returns (0, $value) if everything is okay.

sub attribute_fetch {
  my ($self, $heap, $actor, $id, $attribute) = @_;
  my $repository = $self->[CU_REPOSITORY];

  my ($att_status, $att_owner, $att_value) =
    $self->find_attribute_backwards($repository, $id, $attribute);

  DEB_CURATOR &&
    print( "*** attribute_fetch: actor($actor) id($id) attribute($attribute) ",
           "att_status($att_status) ",
           "att_owner($att_owner) att_value(",
           ((defined $att_value) ? $att_value : '<<undef>>'), ")\n"
         );

  my ($effect_status, $effect_returns) =
    $self->attribute_execute( $heap, $actor, $id, $attribute . CANFETCH,
                              [ $att_value ]
                            );
  return (EPERM, undef) if ( $effect_status
                             or !scalar(@$effect_returns)
                             or !$effect_returns->[0]
                           );

  DEB_CURATOR && (@$effect_returns > 1) &&
    print "\treturns different value: $effect_returns->[1]\n";

  my $old_value = $att_value;
  $att_value = $effect_returns->[1] if (@$effect_returns > 1);

  ($effect_status, $effect_returns) =
    $self->attribute_execute( $heap, $actor, $id, $attribute . DIDFETCH,
                              [ $old_value, $att_value ]
                            );

  if (ref($att_value) eq 'HASH') {
    my %return_att;
    tie( %return_att, 'POE::Attribute::Hash',
         $repository, $attribute, $id, $att_owner
       );
    return (0, \%return_att);
  }

  if (ref($att_value) eq 'ARRAY') {
    my @return_att;
    tie( @return_att, 'POE::Attribute::Array',
         $repository, $attribute, $id, $att_owner
       );
    return (0, \@return_att);
  }

  return (0, $att_value);
}

#------------------------------------------------------------------------------

sub attribute_store {
  my ($self, $heap, $actor, $id, $attribute, $value) = @_;
  my $repository = $self->[CU_REPOSITORY];

  my ($att_status, $att_owner, $att_value) =
    $self->find_attribute_backwards($repository, $id, $attribute);

  DEB_CURATOR &&
    print( "*** attribute_store: actor($actor) id($id) attribute($attribute) ",
           "att_status($att_status) ",
           "att_owner($att_owner) att_value($att_value)\n"
         );

  my ($effect_status, $effect_returns) =
    $self->attribute_execute( $heap, $actor, $id, $attribute . CANSTORE,
                              [ $att_value, $value ]
                            );
  return (EPERM, undef) if ( $effect_status
                             or !scalar(@$effect_returns)
                             or !$effect_returns->[0]
                           );
  $value = $effect_returns->[1] if (@$effect_returns > 1);

  ($att_status, $value) =
    $repository->attribute_store($id, $attribute, $value);
  return ($att_status, undef) if ($att_status);

  ($effect_status, $effect_returns) =
    $self->attribute_execute( $heap, $actor, $id, $attribute . DIDSTORE,
                              [ $att_value, $value ]
                            );

  return (0, $value);
}

#------------------------------------------------------------------------------
# Execute an attribute.
#
# ($status, $return_value) =
#   $c->attribute_execute($heap, $actor, $id, $attribute, $args);
#
# Returns (EINVAL, undef) or (ENOENT, undef) if the repository doesn't
#         like the object ID.
# Returns (ENOSYS, undef) if the attribute doesn't exist.
# Returns (0, \@return_values) if everything is okay.

sub attribute_execute {
  my ($self, $heap, $actor, $id, $attribute, $args) = @_;
  my $repository = $self->[CU_REPOSITORY];

  DEB_CURATOR &&
    print( "||| attribute_execute heap($heap) actor(",
           ((defined $actor) ? $actor : '<<undef>>'),
           ") id($id) attribute($attribute) args($args)\n"
         );

  my ($att_status, $att_owner, $att_value) =
    $self->find_attribute_backwards($repository, $id, $attribute);
  return ($att_status, undef) if ($att_status);

  DEB_CURATOR &&
    print "||| attribute_execute fetched okay\n";

  my ($compile_status, $compile_results) =
    $repository->attribute_compile($att_owner, $attribute, $att_value);

  DEB_CURATOR &&
    print( "||| attribute_compile returns status($compile_status) ",
           "results($compile_results)\n"
         );

  push @{$heap->{call_stack}}, [ $id, $attribute ];
  my @return_values =
    &$compile_results( new POE::Object($self, $id), # object
                       undef,           # session
                       undef,           # kernel
                       $heap,           # heap
                       $attribute,      # state
                       new POE::Object($self, $actor), # sender
                       @$args           # args
                     );
  pop @{$heap->{call_stack}};

  (0, \@return_values);
}

#------------------------------------------------------------------------------
# Resolve an object name into an object reference.
#
# my ($status, $object) = $curator->object($name);
#
# Returns (EFAULT, undef) for 2+ matching objects.
# Returns (ENOENT, undef) for 0 matching objects.
# Returns (0, new POE::Object) for 1 matching object.

sub object {
  my ($self, $name) = @_;

  my $found = $self->[CU_REPOSITORY]->objects_find('name' => $name);
  return new POE::Object($self, $found->[0]) if (@$found == 1);

  $! = (@$found) ? EFAULT : ENOENT;
  return undef;
}

###############################################################################
1;
