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

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub condition_handle {
  my ($self, $handle, $reuse) = @_;
                                        # fix DOSISHness
  binmode($handle);
                                        # do it the Win32 way (XXX incomplete!)
  if ($^O eq 'MSWin32') {
    my $set_it = "1";
                                        # 126 is FIONBIO
    ioctl($handle, 126 | (ord('f')<<8) | (4<<16) | 0x80000000, $set_it)
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

sub _define_accept_state {
  my $self = shift;

  my ($success_event, $failure_event, $listen_handle)
    = @{$self}{'event success', 'event failure', 'handle'};

  $poe_kernel->state
    ( $self->{'state accept'} = $self . ' -> select accept',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym;
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
          $k->call($me, $success_event, $new_socket, $peer_addr, $peer_port);
        }
        elsif ($! != EWOULDBLOCK) {
          $failure_event &&
            $k->call($me, $failure_event, 'accept', ($!+0), $!);
        }
      }
    );

  $poe_kernel->select_read($listen_handle, $self->{'state accept'});
}

#------------------------------------------------------------------------------

sub _define_connect_state {
  my $self = shift;

  my ($success_event, $failure_event, $connect_handle)
    = @{$self}{'event success', 'event failure', 'handle'};

  $poe_kernel->state
    ( $self->{'state noconnect'} = $self . ' -> select noconnect',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
        $k->select($handle);
                                        # acquire and dispatch connect error
        if (defined $failure_event) {
          sysread($handle, my $buf = '', 1);
          $k->call($me, $failure_event, 'connect', ($!+0), $!);
        }
      }
    );

  $poe_kernel->state
    ( $self->{'state connect'} = $self . ' -> select connect',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        $k->select($handle);
        $k->call($me, $success_event, $handle);
      }
    );

  $poe_kernel->select($connect_handle,
                      $self->{'state noconnect'},
                      $self->{'state connect'}
                     );
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'SuccessState') {
      if (defined $event) {
        $self->{'event success'} = $event;
      }
      else {
        carp "SuccessState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'FailureState') {
      if (defined $event) {
        $self->{'event failure'} = $event;
      }
      else {
        carp "FailureState requires an event name.  ignoring undef";
      }
    }
    else {
      carp "ignoring unknown SocketFactory parameter '$name'";
    }
  }

  if (exists $self->{'state accept'}) {
    $poe_kernel->select_read($self->{'handle'}, $self->{'state accept'});
  }
  elsif (exists $self->{'state connect'}) {
    $poe_kernel->select($self->{'handle'},
                        $self->{'state noconnect'},
                        $self->{'state connect'}
                       );
  }
  else {
    die "POE developer error - no state defined";
  }
}

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  croak 'SuccessState required' unless (exists $params{'SuccessState'});
  croak 'FailureState required' unless (exists $params{'FailureState'});

  $params{'SocketDomain'} = AF_INET
    unless (exists $params{'SocketDomain'});
  $params{'SocketType'} = SOCK_STREAM
    unless (exists $params{'SocketType'});

  my $self = bless { 'event success' => $params{'SuccessState'},
                     'event failure' => $params{'FailureState'},
                   }, $type;
  my $socket_handle = gensym;

  my ($socket_domain, $socket_type, $success_event, $failure_event)
    = @params{ 'SocketDomain', 'SocketType', 'SuccessState', 'FailureState'};

  $self->{'socket domain'} = $socket_domain;

  if (($socket_domain == AF_UNIX) || ($socket_domain == PF_UNIX)) {

    carp 'SocketProtocol ignored' if (exists $params{'SocketProtocol'});
    carp 'BindPort ignored'       if (exists $params{'BindPort'});
    carp 'RemotePort ignored'     if (exists $params{'RemotePort'});

    croak 'BindAddress required'  unless (exists $params{'BindAddress'});
    croak 'BindAddress exists'    if (-e $params{'BindAddress'});

    unless (socket($socket_handle, $socket_domain, $socket_type, PF_UNSPEC)) {
      $poe_kernel->yield($failure_event, 'socket', $!+0, $!);
      return undef;
    }

    if (defined(my $ret = $self->condition_handle
                ( $socket_handle,
                  (exists $params{'Reuse'}) ? ((!!$params{'Reuse'})+0) : 0
                )
               )
    ) {
      $poe_kernel->yield($failure_event, @$ret);
      close($socket_handle);
      return undef;
    }

    my $bind_address = &condition_unix_address($params{'BindAddress'});
    my $socket_address = sockaddr_un($bind_address);
    unless ($socket_address) {
      $poe_kernel->yield($failure_event, 'sockaddr_un', $!+0, $!);
      close($socket_handle);
      return undef;
    }

    unless (bind($socket_handle, $socket_address)) {
      $poe_kernel->yield($failure_event, 'bind', $!+0, $!);
      close($socket_handle);
      return undef;
    }

    carp 'RemotePort ignored' if (exists $params{'RemotePort'});

    if (exists $params{RemoteAddress}) {
      my $remote_address =
        condition_unix_address($params{'RemoteAddress'});
      my $socket_address = sockaddr_un($remote_address);
      unless ($socket_address) {
        $poe_kernel->yield($failure_event, 'sockaddr_un', $!+0, $!);
        close $socket_handle;
        return undef;
      }

      unless (connect($socket_handle, $socket_address)) {
        if ($! && ($! != EINPROGRESS)) {
          $poe_kernel->yield($failure_event, 'connect', $!+0, $!);
          close($socket_handle);
          return undef;
        }
      }

      $self->{'handle'} = $socket_handle;
      $self->_define_connect_state();
    }
    else {
      my $listen_queue = $params{'ListenQueue'} || SOMAXCONN;
      ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);

      unless (listen($socket_handle, $listen_queue)) {
        $poe_kernel->yield($failure_event, 'listen', $!+0, $!);
        close($socket_handle);
        return undef;
      }

      $self->{'handle'} = $socket_handle;
      $self->_define_accept_state();
    }
  }

  elsif (($socket_domain == AF_INET) || ($socket_domain == PF_INET)) {

    $params{'SocketProtocol'} = 'tcp'
      unless (exists $params{'SocketProtocol'});

    my $socket_protocol = $params{'SocketProtocol'};

    if ($socket_protocol !~ /^\d+$/) {
      unless ($socket_protocol = getprotobyname($socket_protocol)) {
        $poe_kernel->yield($failure_event, 'getprotobyname', $!+0, $!);
        return undef;
      }
    }

    my $protocol_name = getprotobynumber($socket_protocol);
    unless ($protocol_name) {
      $poe_kernel->yield($failure_event, 'getprotobynumber', $!+0, $!);
      return undef;
    }

    if ($protocol_name !~ /^(tcp|udp)$/) {
      croak "INET sockets only support tcp and udp, not $protocol_name";
    }

    unless (
      socket($socket_handle, $socket_domain, $socket_type, $socket_protocol)
    ) {
      $poe_kernel->yield($failure_event, 'socket', $!+0, $!);
      return undef;
    }

    if (defined(my $ret = $self->condition_handle
                ( $socket_handle,
                  (exists $params{'Reuse'}) ? ((!!$params{'Reuse'})+0) : 0
                )
               )
    ) {
      $poe_kernel->yield($failure_event, @$ret);
      close($socket_handle);
      return undef;
    }
                                        # bind this side of the socket
    my ($bind_address, $bind_port);
    if (exists $params{'BindAddress'}) {
      $bind_address = $params{'BindAddress'};
      (length($bind_address) != 4) &&
        ($bind_address = inet_aton($bind_address));
      unless (defined $bind_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield($failure_event, 'inet_aton', $!+0, $!);
        close $socket_handle;
        return undef;
      }
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

    my $packed_bind_address = sockaddr_in($bind_port, $bind_address);
    unless ($packed_bind_address) {
      $poe_kernel->yield($failure_event, 'sockaddr_in', $!+0, $!);
      close $socket_handle;
      return undef;
    }
    
    unless (bind($socket_handle, $packed_bind_address)) {
      $poe_kernel->yield($failure_event, 'bind', $!+0, $!);
      close($socket_handle);
      return undef;
    }

    if ($protocol_name eq 'tcp') {
                                        # connecting if RemoteAddress
      if (exists $params{RemoteAddress}) {
        croak 'RemotePort required' unless (exists $params{'RemotePort'});
        carp 'ListenQueue ignored' if (exists $params{'ListenQueue'});

        my $remote_port = $params{'RemotePort'};
        if ($remote_port !~ /^\d+$/) {
          unless ($remote_port = getservbyname($remote_port, $protocol_name)) {
            $poe_kernel->yield($failure_event, 'getservbyname', $!+0, $!);
            close($socket_handle);
            return undef;
          }
        }

        my $remote_address = inet_aton($params{'RemoteAddress'});
        unless (defined $remote_address) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield($failure_event, 'inet_aton', $!+0, $!);
          close($socket_handle);
          return undef;
        }

        my $packed_connect_address =
          sockaddr_in($remote_port, $remote_address);
        unless ($packed_connect_address) {
          $poe_kernel->yield($failure_event, 'sockaddr_in', $!+0, $!);
          close $socket_handle;
          return undef;
        }

        unless (connect($socket_handle, $packed_connect_address)) {
          if ($! && ($! != EINPROGRESS)) {
            $poe_kernel->yield($failure_event, 'connect', $!+0, $!);
            close($socket_handle);
            return undef;
          }
        }

        $self->{'handle'} = $socket_handle;
        $self->_define_connect_state();
      }
                                        # listening if no RemoteAddress
      else {
        my $listen_queue = $params{'ListenQueue'} || SOMAXCONN;
        ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);

        unless (listen($socket_handle, $listen_queue)) {
          $poe_kernel->yield($failure_event, 'listen', $!+0, $!);
          close($socket_handle);
          return undef;
        }

        $self->{'handle'} = $socket_handle;
        $self->_define_accept_state();
      }
    }
    elsif ($protocol_name eq 'udp') {
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

  if (exists $self->{'state accept'}) {
    $poe_kernel->state($self->{'state accept'});
    delete $self->{'state accept'};
  }

  if (exists $self->{'state connect'}) {
    $poe_kernel->state($self->{'state connect'});
    delete $self->{'state connect'};
  }

  if (exists $self->{'state noconnect'}) {
    $poe_kernel->state($self->{'state noconnect'});
    delete $self->{'state noconnect'};
  }
}

###############################################################################
1;
