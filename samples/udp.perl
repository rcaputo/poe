#!/usr/bin/perl -w
# $Id$

# Sample program to exercize my knowledge of UDP so it'll grow up to
# be big and strong.

use strict;
use lib '..';
use POE;
use IO::Socket;

#==============================================================================
# Some configuration things.

sub DATAGRAM_MAXLEN () { 1024 }
sub UDP_PORT        () { 5121 }

#==============================================================================
# UDP server.  Uses plain IO::Socket sockets, because SocketFactory
# doesn't support connectionless sockets yet (expect it in 0.0901+).
# Besides, IO::Socket has no reason to block.  Callbacks are pretty
# silly.

sub udp_server_start {
  my ($kernel, $heap, $port) = @_[KERNEL, HEAP, ARG0];
  warn "server: starting\n";

  if (defined 
      ($heap->{socket_handle} =
       IO::Socket::INET->new( Proto => 'udp', LocalPort => UDP_PORT )
      )
     ) {
    $kernel->select_read($heap->{socket_handle}, 'select_read');
  }
  else {
    warn "server: error ", ($!+0), " creating socket: $!\n";
  }
}

#------------------------------------------------------------------------------

sub udp_server_stop {
  warn "server: stopping\n";
  delete $_[HEAP]->{socket_handle};
}

#------------------------------------------------------------------------------

sub udp_server_receive {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  warn "server: select read\n";

  my $remote_socket = recv( $heap->{socket_handle},
                            my $message = '', DATAGRAM_MAXLEN, 0
                          );
  if (defined $remote_socket) {
    my ($remote_port, $remote_addr) = unpack_sockaddr_in($remote_socket);
    my $human_addr = inet_ntoa($remote_addr);

    warn( "server: received message from $human_addr : $remote_port\n",
          "server: message=($message)\n",

        );

    send( $heap->{socket_handle},
          'Test response at ' . time . " (ACK=$message)",
          0, $remote_socket
        );
  }
}

#------------------------------------------------------------------------------

sub udp_server_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  warn "server: $operation error $errnum: $errstr\n";
  delete $heap->{socket_handle};
}

#==============================================================================
# UDP client.  UDP clients don't blok either, so IO::Socket is good.

sub udp_client_start {
  my ($kernel, $heap, $server_addr, $server_port) =
    @_[KERNEL, HEAP, ARG0, ARG1];

  warn "client: starting\n";

  my $socket = IO::Socket::INET->new( Proto => 'udp' );

  if (defined $socket) {
    $heap->{socket_handle} = $socket;
    $heap->{server} = pack_sockaddr_in($server_port, inet_aton($server_addr));
    $kernel->yield('send_datagram');
    $kernel->select_read($socket, 'select_read');
  }
  else {
    warn "client: error ", ($!+0), " creating socket: $!\n";
  }
}

#------------------------------------------------------------------------------

sub udp_client_stop {
  warn "client: stopping\n";
  delete $_[HEAP]->{socket_handle};
}

#------------------------------------------------------------------------------

sub udp_client_send {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  warn "client: alarm ping; sending a message\n";
  send( $heap->{socket_handle},
        'Test message at ' . time, 0, $heap->{server}
      );
  $kernel->delay( 'send_datagram', 1 );
}

#------------------------------------------------------------------------------

sub udp_client_receive {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  warn "client: select read\n";

  my $remote_socket = recv( $heap->{socket_handle},
                            my $message = '', DATAGRAM_MAXLEN, 0
                          );
  if (defined $remote_socket) {
    my ($remote_port, $remote_addr) = unpack_sockaddr_in($remote_socket);
    my $human_addr = inet_ntoa($remote_addr);

    warn( "client: received message from $human_addr : $remote_port\n",
          "client: message=($message)\n",

        );
  }
}

#------------------------------------------------------------------------------

sub udp_client_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  warn "server: $operation error $errnum: $errstr\n";
  delete $heap->{socket_handle};
}

#==============================================================================
# Main loop.

# This is the server session.
POE::Session->create
  ( inline_states =>
    { _start          => \&udp_server_start,
      _stop           => \&udp_server_stop,
      select_read     => \&udp_server_receive,
      socket_made     => \&udp_server_socket,
      socket_error    => \&udp_server_error,
    },
    args => [ UDP_PORT ],
    options => { debug => 1 },
  );

# This is the client session.
POE::Session->create
  ( inline_states =>
    { _start            => \&udp_client_start,
      _stop             => \&udp_client_stop,
      select_read       => \&udp_client_receive,
      send_datagram     => \&udp_client_send,
    },
    args => [ 'localhost', UDP_PORT ],
    options => { debug => 1 },
  );

# Start the main loop until everything is done.
$poe_kernel->run();

exit;

__END__
