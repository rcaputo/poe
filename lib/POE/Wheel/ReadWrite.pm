# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::ReadWrite;

use strict;
use Carp;
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

  my ($handle, $driver, $filter, $state_in, $state_flushed, $state_error) =
    @params{ qw(Handle Driver Filter InputState FlushedState ErrorState) };

  my $self = bless { 'handle' => $handle,
                     'driver' => $driver,
                     'filter' => $filter,
                     'state error' => $state_error,
                     'state flushed' => $state_flushed,
                   }, $type;
                                        # register the select-read handler
  $poe_kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
        if (defined(my $raw_input = $driver->get($handle))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->call($me, $state_in, $cooked_input)
          }
        }
        else {
          $state_error && $k->call($me, $state_error, 'read', ($!+0), $!);
          $k->select_read($handle);
        }
      }
    );
                                        # register the select-write handler
  $poe_kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $writes_pending = $driver->flush($handle);
        if (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
            (defined $state_flushed) && $k->call($me, $state_flushed);
          }
        }
        elsif ($!) {
          $state_error && $k->call($me, $state_error, 'write', ($!+0), $!);
          $k->select_write($handle);
        }
      }
    );

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

  if ($self->{'state write'}) {
    $poe_kernel->state($self->{'state write'});
    delete $self->{'state write'};
  }
}

#------------------------------------------------------------------------------

sub put {
  my ($self, @chunks) = @_;
  if ($self->{'driver'}->put($self->{'filter'}->put(\@chunks))) {
    $poe_kernel->select_write($self->{'handle'}, $self->{'state write'});
  }
}

###############################################################################
1;
