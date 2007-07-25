#!/usr/bin/perl -w
# $Id$

# Exercises the ListenAccept wheel.

use strict;
use lib qw(./mylib ../mylib);
use IO::Socket;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More;
use POE qw(Wheel::ListenAccept Wheel::SocketFactory);

unless (-f "run_network_tests") {
  plan skip_all => "Network access (and permission) required to run this test";
}

plan tests => 2;

my $bound_port;

### A listening session.
sub listener_start {
  my $heap = $_[HEAP];

  my $listening_socket = IO::Socket::INET->new(
    LocalPort => 0,
    Listen    => 5,
    Proto     => 'tcp',
    Reuse     => 'yes',
  );

  if (defined $listening_socket) {
    pass("created listening socket");
  }
  else {
    fail("created listening socket");
    fail("listening socket accepted connections");
    return;
  }

  $bound_port = (sockaddr_in(getsockname($listening_socket)))[0];

  $heap->{listener_wheel} = POE::Wheel::ListenAccept->new(
    Handle      => $listening_socket,
    AcceptEvent => 'got_connection_nonexistent',
    ErrorEvent  => 'got_error_nonexistent'
  );

  $heap->{listener_wheel}->event(
    AcceptEvent => 'got_connection',
    ErrorEvent  => 'got_error'
  );

  $heap->{accept_count} = 0;
  $_[KERNEL]->delay( got_timeout => 15 );
}

sub listener_stop {
  ok(
    $_[HEAP]->{accept_count} == 5,
    "listening socket accepted connections"
  );
}

sub listener_got_connection {
  $_[HEAP]->{accept_count}++;
  $_[KERNEL]->delay( got_timeout => 3 );
}

sub listener_got_error {
  delete $_[HEAP]->{listener_wheel};
}

sub listener_got_timeout {
  delete $_[HEAP]->{listener_wheel};
}

### A connecting session.
sub connector_start {
  $_[HEAP]->{connector_wheel} = POE::Wheel::SocketFactory->new(
    RemoteAddress => '127.0.0.1',
    RemotePort    => $bound_port,
    SuccessEvent  => 'got_connection',
    FailureEvent  => 'got_error',
  );
}

sub connector_got_connection {
  delete $_[HEAP]->{connector_wheel};
}

sub connector_got_error {
  delete $_[HEAP]->{connector_wheel};
}

### Main loop.

POE::Session->create(
  inline_states => {
    _start         => \&listener_start,
    _stop          => \&listener_stop,
    got_connection => \&listener_got_connection,
    got_error      => \&listener_got_error,
    got_timeout    => \&listener_got_timeout,
  }
);

for (my $connector_count=0; $connector_count < 5; $connector_count++) {
  POE::Session->create(
    inline_states => {
      _start         => \&connector_start,
      got_connection => \&connector_got_connection,
      got_error      => \&connector_got_error,
    }
  );
}

$poe_kernel->run();

1;
