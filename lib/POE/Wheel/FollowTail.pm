# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  croak "Handle required"     unless (exists $params{'Handle'});
  croak "Driver required"     unless (exists $params{'Driver'});
  croak "Filter required"     unless (exists $params{'Filter'});
  croak "InputState required" unless (exists $params{'InputState'});

  my ($handle, $driver, $filter, $state_in, $state_error) =
    @params{ qw(Handle Driver Filter InputState ErrorState) };

  my $poll_interval = ( (exists $params{'PollInterval'})
                        ? $params{'PollInterval'}
                        : 1
                      );

  my $self = bless { 'handle'   => $handle,
                     'driver'   => $driver,
                     'filter'   => $filter,
                     'interval' => $poll_interval,
                     'event input' => $params{'InputState'},
                     'event error' => $params{'ErrorEvent'},
                   }, $type;
                                        # register the input state
  $self->_define_read_state();
                                        # set the file position to the end
  seek($handle, 0, SEEK_END);
  seek($handle, -4096, SEEK_CUR);
                                        # discard partial input chunks
  while (defined(my $raw_input = $driver->get($handle))) {
    $filter->get($raw_input);
  }
                                        # register the alarm state
  $poe_kernel->state
    ( $self->{'state wake'} = $self . ' -> alarm',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my $k = $_[KERNEL];
        $k->select_read($handle, $self->{'state read'});
      }
    );
                                        # nudge the wheel into action
  $poe_kernel->select($handle, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'InputState') {
      if (defined $event) {
        $self->{'event input'} = $event;
      }
      else {
        carp "InputState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->{'event error'} = $event;
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
    }
  }

  $self->_define_read_state();
}

#------------------------------------------------------------------------------

sub _define_read_state {
  my $self = shift;
                                        # stupid closure trick
  my ($event_in, $event_error, $filter, $driver, $poll_interval)
    = @{$self}{'event input', 'event error', 'filter', 'driver', 'interval'};
                                        # check for file activity
  $poe_kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $ses, $hdl) = @_[KERNEL, SESSION, ARG0];
        
        while (defined(my $raw_input = $driver->get($hdl))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->call($ses, $event_in, $cooked_input)
          }
        }

        $k->select_read($hdl);

        if ($!) {
          defined($event_error)
            && $k->call($ses, $event_error, 'read', ($!+0), $!);
        }
        else {
          $k->delay($self->{'state wake'}, $poll_interval);
        }
      }
    );
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
