# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::ListenAccept;

use strict;
use Carp;
use POSIX qw(EAGAIN);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $kernel = shift;
  my %params = @_;

  croak "Handle required" unless (exists $params{'Handle'});
  croak "AcceptState required" unless (exists $params{'AcceptState'});

  my ($handle, $state_accept, $state_error) =
    @params{ qw(Handle AcceptState ErrorState) };

  my $self = bless { 'handle' => $handle,
                     'kernel' => $kernel,
                   }, $type;
                                        # register the select-read handler
  $kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
        my ($k, $me, $from, $handle) = @_;

        my $new_socket = $handle->accept();

        if ($new_socket) {
          $k->post($me, $state_accept, $new_socket);
        }
        elsif ($! != EAGAIN) {
          $state_error && $k->post($me, $state_error, 'accept', ($!+0), $!);
        }
      }
    );

  $kernel->select($handle, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $self->{'kernel'}->select($self->{'handle'});

  if ($self->{'state read'}) {
    $self->{'kernel'}->state($self->{'state read'});
    delete $self->{'state read'};
  }
}

###############################################################################
1;
