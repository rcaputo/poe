# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  croak "Handle required" unless (exists $params{'Handle'});
  croak "Driver required" unless (exists $params{'Driver'});
  croak "Filter required" unless (exists $params{'Filter'});
  croak "InputState required" unless (exists $params{'InputState'});

  my ($handle, $driver, $filter, $state_in, $state_error) =
    @params{ qw(Handle Driver Filter InputState ErrorState) };

  my $self = bless { 'handle' => $handle,
                     'driver' => $driver,
                     'filter' => $filter,
                   }, $type;
                                        # pre-declare (whee!)
  $self->{'state read'} = $self . ' -> select read';
  $self->{'state wake'} = $self . ' -> alarm';
                                        # check for file activity
  $poe_kernel->state
    ( $self->{'state read'},
      sub {
        my ($k, $ses, $hdl) = @_[KERNEL, SESSION, ARG0];
        
        while (defined(my $raw_input = $driver->get($hdl))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->call($ses, $state_in, $cooked_input)
          }
        }

        $k->select_read($hdl);

        if ($!) {
          defined($state_error)
            && $k->call($ses, $state_error, 'read', ($!+0), $!);
        }
        else {
          $k->delay($self->{'state wake'}, 1);
        }
      }
    );
                                        # wake up and smell the filehandle
  $poe_kernel->state
    ( $self->{'state wake'},
      sub {
        my $k = $_[KERNEL];
        $k->select_read($handle, $self->{'state read'});
      }
    );
                                        # set the file position to the end
  seek($handle, 0, SEEK_END);
  seek($handle, -4096, SEEK_CUR);
                                        # discard partial lines and stuff
  while (defined(my $raw_input = $driver->get($handle))) {
    $filter->get($raw_input);
  }
                                        # nudge the wheel into action
  $poe_kernel->select($handle, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->{'handle'});

  if ($self->{'state read'}) {
    $poe_kernel->state($self->{'state read'});
    delete $self->{'state read'};
  }

  if ($self->{'state wake'}) {
    $poe_kernel->state($self->{'state wake'});
    delete $self->{'state wake'};
  }
}

###############################################################################
1;
