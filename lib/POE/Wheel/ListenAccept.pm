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

  croak "Handle required" unless (exists $params{'Handle'});
  croak "AcceptState required" unless (exists $params{'AcceptState'});

  my ($handle, $state_accept, $state_error) =
    @params{ qw(Handle AcceptState ErrorState) };

  my $self = bless { 'handle' => $handle,
                   }, $type;
                                        # register the select-read handler
  $poe_kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = $handle->accept();

        if ($new_socket) {
          $k->call($me, $state_accept, $new_socket);
        }
        elsif ($! != EAGAIN) {
          $state_error &&
            $k->call($me, $state_error, 'accept', ($!+0), $!);
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
}

###############################################################################
1;
