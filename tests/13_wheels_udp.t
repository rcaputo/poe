#!/usr/bin/perl -w
# $Id$

# Exercises the wheels commonly used with UDP sockets.

use strict;
use lib qw(./lib ../lib .. .);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Socket;

use POE qw( Wheel::SocketFactory );

my $max_send_count = 10;

# Congratulations! We made it this far!
test_setup(13);

###############################################################################
# Both a UDP server and a client in one session.  This is a contrived
# example of using two sockets/filehandles at once.
# samples/proxy.perl does something similar.

sub udp_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  $heap->{peer_a_setup_wheel} =
    POE::Wheel::SocketFactory->new
      ( BindAddress    => '127.0.0.1',
        BindPort       => 0,
        SocketProtocol => 'udp',
        Reuse          => 'yes',
        SuccessEvent   => 'ev_peer_a_socket',
        FailureEvent   => 'ev_peer_a_error',
      );

  $heap->{peer_a_id} = $heap->{peer_a_setup_wheel}->ID;

  $heap->{peer_b_setup_wheel} =
    POE::Wheel::SocketFactory->new
      ( BindAddress    => '127.0.0.1',
        BindPort       => 0,
        SocketProtocol => 'udp',
        Reuse          => 'yes',
        SuccessEvent   => 'ev_peer_b_socket',
        FailureEvent   => 'ev_peer_b_error',
      );

  $heap->{peer_b_id} = $heap->{peer_b_setup_wheel}->ID;

  $heap->{peer_a_recv_error} = 0;
  $heap->{peer_a_send_error} = 0;
  $heap->{peer_a_sock_error} = 0;

  $heap->{peer_b_recv_error} = 0;
  $heap->{peer_b_send_error} = 0;
  $heap->{peer_b_sock_error} = 0;

  $heap->{peer_a_send_count} = 0;
  $heap->{peer_b_send_count} = 0;

  $heap->{test_one} = 1;
  $heap->{test_two} = 1;

  $kernel->delay( ev_took_too_long => 5 );
}

sub udp_stop {
  my $heap = $_[HEAP];

  &ok_if( 1, $heap->{test_one} );
  &ok_if( 2, $heap->{test_two} );

  &ok_unless(5,  $heap->{peer_a_recv_error});
  &ok_unless(6,  $heap->{peer_a_send_error});
  &ok_unless(7,  $heap->{peer_a_sock_error});

  &ok_unless(8,  $heap->{peer_b_recv_error});
  &ok_unless(9,  $heap->{peer_b_send_error});
  &ok_unless(10, $heap->{peer_b_sock_error});

  &ok_if( 11,
          $heap->{peer_a_send_count} == $max_send_count,
          "only sent $heap->{peer_a_send_count}"
        );
  &ok_if( 12, $heap->{peer_b_send_count} == $max_send_count,
          "only sent $heap->{peer_b_send_count}"
        );
}

sub udp_peer_a_socket {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  &ok(3);

  delete $heap->{peer_a_setup_wheel};
  $heap->{peer_a_socket_handle} = $socket;
  $kernel->select_read( $socket, 'ev_peer_a_input' );

  if ( defined($heap->{peer_a_socket_handle}) and
       defined($heap->{peer_b_socket_handle})
     ) {
    my $peer_b_address = getsockname($heap->{peer_b_socket_handle});
    die unless defined $peer_b_address;
    my ($peer_b_port, $peer_b_addr) = unpack_sockaddr_in($peer_b_address);
    $heap->{peer_a_send_count}++;
    send( $socket, '1: this is a test', 0, $peer_b_address )
      or $heap->{peer_a_send_error}++;
  }
}

sub udp_peer_b_socket {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  &ok(4);

  delete $heap->{peer_b_setup_wheel};
  $heap->{peer_b_socket_handle} = $socket;
  $kernel->select_read( $socket, 'ev_peer_b_input' );

  if ( defined($heap->{peer_a_socket_handle}) and
       defined($heap->{peer_b_socket_handle})
     ) {
    my $peer_a_address = getsockname($heap->{peer_a_socket_handle});
    die unless defined $peer_a_address;
    my ($peer_a_port, $peer_a_addr) = unpack_sockaddr_in($peer_a_address);
    $heap->{peer_b_send_count}++;
    send( $socket, '1: this is a test', 0, $peer_a_address )
      or $heap->{peer_b_send_error}++;
  }
}

sub udp_peer_a_error {
  my ($heap, $wheel_id) = @_[HEAP, ARG3];
  if ($wheel_id == $heap->{peer_a_id}) {
    delete $heap->{peer_a_setup_wheel};
    $heap->{test_one} = 0;
  }
  $heap->{peer_a_sock_error}++;
}

sub udp_peer_b_error {
  my ($heap, $wheel_id) = @_[HEAP, ARG3];
  if ($wheel_id == $heap->{peer_b_id}) {
    delete $heap->{peer_b_setup_wheel};
    $heap->{test_two} = 0;
  }
  $heap->{peer_b_sock_error}++;
}

sub udp_peer_a_input {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  my $remote_socket = recv( $socket, my $message = '', 1024, 0 );

  if (defined $remote_socket) {
    if ($heap->{peer_a_send_count} < $max_send_count) {
      $message =~ tr/a-zA-Z/n-za-mN-ZA-M/; # rot13
      $heap->{peer_a_send_count}++;
      send( $socket, $message, 0, $remote_socket )
        or $heap->{peer_a_send_error}++;
    }
    else {
      $kernel->select_read($socket);
    }
  }
  else {
    $heap->{peer_a_recv_error}++;
  }
}

sub udp_peer_b_input {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  my $remote_socket = recv( $socket, my $message = '', 1024, 0 );

  if (defined $remote_socket) {
    if ($heap->{peer_b_send_count} < $max_send_count) {
      $message =~ tr/a-zA-Z/n-za-mN-ZA-M/; # rot13
      $heap->{peer_b_send_count}++;
      send( $socket, $message, 0, $remote_socket )
        or $heap->{peer_b_send_error}++;
    }
    else {
      $kernel->select_read($socket);
    }
  }
  else {
    $heap->{peer_b_recv_error}++;
  }
}

sub udp_timeout {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  if (defined $heap->{peer_a_socket_handle}) {
    $kernel->select($heap->{peer_a_socket_handle});
    delete $heap->{peer_a_socket_handle};
  }

  if (defined $heap->{peer_b_socket_handle}) {
    $kernel->select($heap->{peer_b_socket_handle});
    delete $heap->{peer_b_socket_handle};
  }
}

###############################################################################

POE::Session->create
  ( inline_states =>
    { _start           => \&udp_start,
      _stop            => \&udp_stop,
      ev_took_too_long => \&udp_timeout,
      ev_peer_a_socket => \&udp_peer_a_socket,
      ev_peer_a_error  => \&udp_peer_a_error,
      ev_peer_a_input  => \&udp_peer_a_input,
      ev_peer_b_socket => \&udp_peer_b_socket,
      ev_peer_b_error  => \&udp_peer_b_error,
      ev_peer_b_input  => \&udp_peer_b_input,
    },
  );

$poe_kernel->run();

&ok(13);
&results;

exit;
