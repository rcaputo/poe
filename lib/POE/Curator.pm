# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Curator;

use strict;
use POSIX qw(errno_h);

use Carp;

my $repository;

#------------------------------------------------------------------------------
# Initialize certain aspects of the object manager.
#
#   initialize POE::Curator( Repository => \@repository );

sub initialize {
  my ($package, %param) = @_;

  croak "Repository is a required parameter"
    unless (exists $param{Repository});

  $repository = delete $param{Repository};

  my @bad_parameters = sort(keys(%param));
  while (my $bad_param = shift(@bad_parameters)) {
    if (@bad_parameters) {
      carp "Unknown parameter '$bad_param'";
    }
    else {
      croak "Unknown parameter '$bad_param'";
    }
  }
}

#------------------------------------------------------------------------------

sub att_fetch {
  my ($id, $attribute) = @_;

  return (ENOENT, undef)
    unless ( ($id >= 0) &&
             ($id < scalar(@$repository)) &&
             (defined $repository->[$id]) &&
             (exists $repository->[$id]->{$attribute})
           );

  return (0, $repository->[$id]->{$attribute});
}

#------------------------------------------------------------------------------
# Return a single object, from its name.

sub object {
  my $name = shift;

  my @found;
  for (my $id=0; $id<scalar(@$repository); $id++) {
    next unless (defined(my $object = $repository->[$id]));
    push(@found, $id) if ($object->{name} eq $name);
  }

  return new POE::Object($found[0]) if (@found == 1);

  if (@found) {
    $! = EFAULT;
    return undef;
  }

  $! = ENOENT;
  return undef;
}

###############################################################################
1;
