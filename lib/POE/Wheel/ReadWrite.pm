# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::ReadWrite;

use strict;
use Carp;
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  croak "Handle required" unless (exists $params{'Handle'});
  croak "Driver required" unless (exists $params{'Driver'});
  croak "Filter required" unless (exists $params{'Filter'});

  my $self = bless { 'handle'        => $params{'Handle'},
                     'driver'        => $params{'Driver'},
                     'filter'        => $params{'Filter'},
                     'event input'   => $params{'InputState'},
                     'event error'   => $params{'ErrorState'},
                     'event flushed' => $params{'FlushedState'},
                   }, $type;
                                        # register private event handlers
  $self->_define_read_state();
  $self->_define_write_state();

  $self;
}

#------------------------------------------------------------------------------
# Redefine events.

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'InputState') {
      $self->{'event input'} = $event;
    }
    elsif ($name eq 'ErrorState') {
      $self->{'event error'} = $event;
    }
    elsif ($name eq 'FlushedState') {
      $self->{'event flushed'} = $event;
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
    }
  }

  $self->_define_read_state();
  $self->_define_write_state();
}

#------------------------------------------------------------------------------
# Re/define the read state.  Moved out of new so that it can be redone
# whenever the input and/or error states are changed.

sub _define_read_state {
  my $self = shift;
                                        # stupid closure trick
  my ($event_in, $event_error, $driver, $filter, $handle) =
    @{$self}{'event input', 'event error', 'driver', 'filter', 'handle'};
                                        # register the select-read handler
  if (defined $event_in) {
    $poe_kernel->state
      ( $self->{'state read'} = $self . ' -> select read',
        sub {
                                        # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$filter->get($raw_input)}) {
              $k->call($me, $event_in, $cooked_input)
            }
          }
          else {
            $event_error && $k->call($me, $event_error, 'read', ($!+0), $!);
            $k->select_read($handle);
          }
        }
      );
                                        # register the state's select
    $poe_kernel->select_read($handle, $self->{'state read'});
  }
                                        # undefine the select, just in case
  else {
    $poe_kernel->select_read($handle)
  }
}

#------------------------------------------------------------------------------
# Re/define the write state.  Moved out of new so that it can be
# redone whenever the input and/or error states are changed.

sub _define_write_state {
  my $self = shift;
                                        # stupid closure trick
  my ($event_error, $event_flushed, $handle, $driver) =
    @{$self}{'event error', 'event flushed', 'handle', 'driver'};
                                        # register the select-write handler
  $poe_kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $writes_pending = $driver->flush($handle);
        if (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
            (defined $event_flushed) && $k->call($me, $event_flushed);
          }
        }
        elsif ($!) {
          $event_error && $k->call($me, $event_error, 'write', ($!+0), $!);
          $k->select_write($handle);
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
