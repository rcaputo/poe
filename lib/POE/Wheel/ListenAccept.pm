# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::ListenAccept;

use strict;
use Carp;
use POSIX qw(EAGAIN);
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  croak "Handle required"      unless (exists $params{'Handle'});
  croak "AcceptState required" unless (exists $params{'AcceptState'});

  my $self = bless { 'handle'       => $params{'Handle'},
                     'event accept' => $params{'AcceptState'},
                     'event error'  => $params{'ErrorState'},
                   }, $type;
                                        # register private event handlers
  $self->_define_accept_state();
  $poe_kernel->select($self->{'handle'}, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'AcceptState') {
      if (defined $event) {
        $self->{'event accept'} = $event;
      }
      else {
        carp "AcceptState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->{'event error'} = $event;
    }
    else {
      carp "ignoring unknown ListenAccept parameter '$name'";
    }
  }

  $self->_define_accept_state();
}

#------------------------------------------------------------------------------

sub _define_accept_state {
  my $self = shift;
                                        # stupid closure trick
  my ($event_accept, $event_error, $handle) =
    @{$self}{'event accept', 'event error', 'handle'};
                                        # register the select-read handler
  $poe_kernel->state
    ( $self->{'state read'} =  $self . ' -> select read',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = $handle->accept();

        if ($new_socket) {
          $k->call($me, $event_accept, $new_socket);
        }
        elsif ($! != EAGAIN) {
          $event_error &&
            $k->call($me, $event_error, 'accept', ($!+0), $!);
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
}

###############################################################################
1;
