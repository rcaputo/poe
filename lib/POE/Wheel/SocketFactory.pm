# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

#------------------------------------------------------------------------------

package POE::Wheel::SocketFactory;

use strict;
use Carp;
use Symbol;

use POSIX qw(fcntl_h errno_h);
use Socket;
use POE;

#------------------------------------------------------------------------------

sub condition_handle {
  my ($self, $handle, $reuse) = @_;

  binmode($handle);
                                        # do it the Win32 way
  if ($^O eq '"MSWin32') {
    my $set_it = "1";
    ioctl($handle, 126, $set_it)
      or return ['ioctl', $!+0, $!];
  }
                                        # do it the way everyone else does
  else {
    my $flags = fcntl($handle, F_GETFL, 0)
      or return ['fcntl', $!+0, $!];
    $flags = fcntl($handle, F_SETFL, $flags | O_NONBLOCK)
      or return ['fcntl', $!+0, $!];
  }
                                        # reuse the address, maybe
  setsockopt($handle, SOL_SOCKET, SO_REUSEADDR, $reuse)
    or return ['setsockopt', $!+0, $!];

  return undef;
}

#------------------------------------------------------------------------------
# translate UNIX addresses to system-dependent representation, if necessary

sub condition_unix_address {
  my ($address) = @_;
                                        # OS/2 wants backwhacks and \socket\...
  if ($^O eq 'os2') {
    $address =~ tr[\\][/];
    if ($address !~ m{^/socket/}) {
      $address =~ s{^/?}{/socket/};
    }
    $address =~ tr[/][\\];
  }

  $address;
}

#------------------------------------------------------------------------------

sub register_listen_accept {
  my ($self, $listen_handle, $success_state, $failure_state) = @_;

  $poe_kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym();
        my $peer = accept($new_socket, $handle);

        if ($peer) {
          my ($peer_addr, $peer_port);
          if ($self->{'socket domain'} == AF_UNIX) {
            $peer_addr = $peer_port = undef;
          }
          elsif ($self->{'socket domain'} == AF_INET) {
            ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
          }
          else {
            die "sanity failure: socket domain == $self->{'socket domain'}";
          }
          $k->call($me, $success_state, $new_socket, $peer_addr, $peer_port);
        }
        elsif ($! != EWOULDBLOCK) {
          $failure_state &&
            $k->call($me, $failure_state, 'accept', ($!+0), $!);
        }
      }
    );

  $poe_kernel->select_read($listen_handle, $self->{'state read'});
}

#------------------------------------------------------------------------------

sub register_connect {
  my ($self, $connect_handle, $success_state, $failure_state) = @_;

  $poe_kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
        $k->select($handle);
        $k->call($me, $success_state, $handle);
      }
    );
  $poe_kernel->select_write($connect_handle, $self->{'state write'});

#   $poe_kernel->state
#     ( $self->{'state read'} = $self . ' -> select read',
#       sub {
#         my ($k, $handle) = @_[KERNEL, ARG0];
#         sysread($handle, my $buffer = '', 0, 0);
#         if ($! && ($! != EINPROGRESS)) {
#           $k->yield($failure_state, 'connect', $!+0, $!);
#           $k->select($handle);
#           close($handle);
#         }
#       }
#     );
#   $poe_kernel->select_read($connect_handle, $self->{'state read'});
}

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  my $self = bless { }, $type;

  my $socket_handle = gensym();

  croak 'SuccessState required' unless (exists $params{'SuccessState'});
  croak 'FailureState required' unless (exists $params{'FailureState'});
  croak 'SocketDomain required' unless (exists $params{'SocketDomain'});
  croak 'SocketType required'   unless (exists $params{'SocketType'});

  my ($socket_domain, $socket_type, $success_state, $failure_state
     ) = @params{ 'SocketDomain', 'SocketType', 'SuccessState', 'FailureState'
                };

  $self->{'socket domain'} = $socket_domain;

  if (($socket_domain == AF_UNIX) || ($socket_domain == PF_UNIX)) {

    carp 'SocketProtocol ignored' if (exists $params{'SocketProtocol'});
    carp 'BindPort ignored'       if (exists $params{'BindPort'});
    carp 'RemotePort ignored'     if (exists $params{'RemotePort'});

    croak 'BindAddress required'  unless (exists $params{'BindAddress'});
    croak 'BindAddress exists'    if (-e $params{'BindAddress'});

    unless (socket($socket_handle, $socket_domain, $socket_type, PF_UNSPEC)) {
      $poe_kernel->yield($failure_state, 'socket', $!+0, $!);
      return undef;
    }

    if (defined(my $ret = $self->condition_handle
                ( $socket_handle,
                  (exists $params{'Reuse'}) ? ((!!$params{'Reuse'})+0) : 0
                )
               )
    ) {
      $poe_kernel->yield($failure_state, @$ret);
      close($socket_handle);
      return undef;
    }

    my $bind_address = &condition_unix_address($params{'BindAddress'});

    unless (bind($socket_handle, sockaddr_un($bind_address))) {
      $poe_kernel->yield($failure_state, 'bind', $!+0, $!);
      close($socket_handle);
      return undef;
    }

    if (exists $params{'ListenQueue'}) {
      my $listen_queue = $params{'ListenQueue'};
      ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);

      carp 'RemoteAddress ignored' if (exists $params{'RemoteAddress'});
      carp 'RemotePort ignored' if (exists $params{'RemotePort'});

      unless (listen($socket_handle, $listen_queue)) {
        $poe_kernel->yield($failure_state, 'listen', $!+0, $!);
        close($socket_handle);
        return undef;
      }

      $self->register_listen_accept($socket_handle,
                                    $success_state, $failure_state
                                   );
      $self->{'handle'} = $socket_handle;
    }
    else {
      croak 'RemoteAddress required' unless (exists $params{'RemoteAddress'});
      carp 'RemotePort ignored' if (exists $params{'RemotePort'});

      my $remote_address =
        condition_unix_address($params{'RemoteAddress'});

      unless (connect($socket_handle, sockaddr_un($remote_address))) {
        if ($! && ($! != EINPROGRESS)) {
          $poe_kernel->yield($failure_state, 'connect', $!+0, $!);
          close($socket_handle);
          return undef;
        }
      }

      $self->register_connect($socket_handle, $success_state, $failure_state);
    }
  }

  elsif (($socket_domain == AF_INET) || ($socket_domain == PF_INET)) {

    croak 'SocketProtocol required' unless (exists $params{'SocketProtocol'});
    my $socket_protocol = $params{'SocketProtocol'};
    if ($socket_protocol !~ /^\d+$/) {
      unless ($socket_protocol = getprotobyname($socket_protocol)) {
        $poe_kernel->yield($failure_state, 'getprotobyname', $!+0, $!);
        return undef;
      }
    }

    my $protocol_name = getprotobynumber($socket_protocol);
    unless ($protocol_name) {
      $poe_kernel->yield($failure_state, 'getprotobynumber', $!+0, $!);
      return undef;
    }

    if ($protocol_name !~ /^(tcp|udp)$/) {
      croak "INET sockets only support tcp and udp, not $protocol_name";
    }

    unless (
      socket($socket_handle, $socket_domain, $socket_type, $socket_protocol)
    ) {
      $poe_kernel->yield($failure_state, 'socket', $!+0, $!);
      return undef;
    }

    if (defined(my $ret = $self->condition_handle
                ( $socket_handle,
                  (exists $params{'Reuse'}) ? ((!!$params{'Reuse'})+0) : 0
                )
               )
    ) {
      $poe_kernel->yield($failure_state, @$ret);
      close($socket_handle);
      return undef;
    }

    if ($protocol_name eq 'tcp') {

      if (exists $params{'ListenQueue'}) {
        my $listen_queue = $params{'ListenQueue'};
        ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);

        carp 'RemoteAddress ignored' if (exists $params{'RemoteAddress'});
        carp 'RemotePort ignored' if (exists $params{'RemotePort'});

        my ($bind_address, $bind_port);
        if (exists $params{'BindAddress'}) {
          $bind_address = inet_aton($params{'BindAddress'});
        }
        else {
          $bind_address = INADDR_ANY;
        }

        if (exists $params{'BindPort'}) {
          $bind_port = $params{'BindPort'};
          if ($bind_port !~ /^\d+$/) {
            $bind_port = getservbyname($bind_port, $protocol_name);
          }
        }
        else {
          $bind_port = 0;
        }

        unless (bind($socket_handle, sockaddr_in($bind_port, $bind_address))) {
          $poe_kernel->yield($failure_state, 'bind', $!+0, $!);
          close($socket_handle);
          return undef;
        }

        unless (listen($socket_handle, $listen_queue)) {
          $poe_kernel->yield($failure_state, 'listen', $!+0, $!);
          close($socket_handle);
          return undef;
        }

        $self->register_listen_accept($socket_handle,
                                      $success_state, $failure_state
                                     );
      }
                                        # connecting socket
      else {
        carp 'BindAddress ignored' if (exists $params{'BindAddress'});
        carp 'BindPort ignored' if (exists $params{'BindPort'});
        croak 'RemoteAddress required'
          unless (exists $params{'RemoteAddress'});
        croak 'RemotePort required' unless (exists $params{'RemotePort'});

        my $remote_port = $params{'RemotePort'};
        if ($remote_port !~ /^\d+$/) {
          unless ($remote_port = getservbyname($remote_port, $protocol_name)) {
            $poe_kernel->yield($failure_state, 'getservbyname', $!+0, $!);
            close($socket_handle);
            return undef;
          }
        }

        my $remote_address = inet_aton($params{'RemoteAddress'});

        unless (
          connect($socket_handle, sockaddr_in($remote_port, $remote_address))
        ) {
          if ($! && ($! != EINPROGRESS)) {
            $poe_kernel->yield($failure_state, 'connect', $!+0, $!);
            close($socket_handle);
            return undef;
          }
        }

        $self->register_connect($socket_handle,
                                $success_state, $failure_state
                               );
      }
    }
    elsif ($protocol_name eq 'udp') {

      # udp
      die 'udp inet socket not implemented';

    }
    else {
      croak "INET sockets only support tcp and udp, not $protocol_name";
    }
  }

  else {
    croak 'unsupported SocketDomain';
  }

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  if (exists $self->{'handle'}) {
    $poe_kernel->select($self->{'handle'});
  }

  if (exists $self->{'state read'}) {
    $poe_kernel->state($self->{'state read'});
    delete $self->{'state read'};
  }
}

###############################################################################
1;
