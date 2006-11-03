#!/usr/bin/perl -w
# $Id$

# Exercises the wheels commonly used with TCP sockets.

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Socket;

use POE qw(
  Component::Server::TCP
  Wheel::ReadWrite
  Filter::Line
  Driver::SysRW
);

my $tcp_server_port = 31909;

use Test::More;

unless (-f "run_network_tests") {
  plan skip_all => "Network access (and permission) required to run this test";
}

plan tests => 9;

###############################################################################
# A generic server session.

sub sss_new {
  my ($socket, $peer_addr, $peer_port) = @_;
  POE::Session->create(
    inline_states => {
      _start    => \&sss_start,
      _stop     => \&sss_stop,
      got_line  => \&sss_line,
      got_error => \&sss_error,
      got_flush => \&sss_flush,
      _child => sub { },
    },
    args => [ $socket, $peer_addr, $peer_port ],
  );
}

sub sss_start {
  my ($heap, $socket, $peer_addr, $peer_port) = @_[HEAP, ARG0..ARG2];

  # Swap the SocketFactory for the ReadWrite.  This exercises a subtle
  # bug in SocketFactory which should now be fixed.
  $heap->{wheel} = POE::Wheel::ReadWrite->new(
    Handle       => $socket,
    Driver       => POE::Driver::SysRW->new( BlockSize => 10 ),
    Filter       => POE::Filter::Line->new(),
    InputEvent   => 'got_line',
    ErrorEvent   => 'got_error',
    FlushedEvent => 'got_flush',
  );

  $heap->{wheel_id} = $heap->{wheel}->ID;
  $heap->{test_two} = 1;

  $heap->{flush_count} = 0;
  $heap->{put_count}   = 0;
}

sub sss_line {
  my ($heap, $line) = @_[HEAP, ARG0];

  $line =~ tr/a-zA-Z/n-za-mN-ZA-M/; # rot13

  $heap->{wheel}->put($line);
  $heap->{put_count}++;
}

sub sss_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];

  ok(!$errnum, "sss expecting errnum 0; got $errnum");
  $heap->{test_two} = 0 if $errnum;

  delete $heap->{wheel};
}

sub sss_flush {
  $_[HEAP]->{flush_count}++;
}

sub sss_stop {
  my $heap = $_[HEAP];
  ok($heap->{test_two}, "test two");
  ok($heap->{put_count} == $heap->{flush_count}, "flushed all put data");
}

###############################################################################
# A TCP socket client.

sub client_tcp_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::SocketFactory->new(
    RemoteAddress  => '127.0.0.1',
    RemotePort    => $tcp_server_port,
    SuccessEvent  => 'got_server',
    FailureEvent  => 'got_error',
  );

  $heap->{socket_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_five} = 1;
}

sub client_tcp_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ok($heap->{test_five}, "test five");
  ok($heap->{test_seven}, "test seven");
  $_[KERNEL]->post( tcp_server => 'shutdown' );
}

sub client_tcp_connected {
  my ($heap, $server_socket) = @_[HEAP, ARG0];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::ReadWrite->new(
    Handle       => $server_socket,
    Driver       => POE::Driver::SysRW->new( BlockSize => 10 ),
    Filter       => POE::Filter::Line->new(),
    InputEvent   => 'got_line',
    ErrorEvent   => 'got_error',
    FlushedEvent => 'got_flush',
  );

  $heap->{readwrite_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_seven} = 1;

  $heap->{flush_count} = 0;
  $heap->{put_count}   = 1;
  $heap->{wheel}->put( '1: this is a test' );

  ok($heap->{wheel}->get_driver_out_octets() == 19, "buffered 19 octets");
  ok($heap->{wheel}->get_driver_out_messages() == 1, "buffered 1 message");
}

sub client_tcp_got_line {
  my ($heap, $line) = @_[HEAP, ARG0];

  if ($line =~ s/^1: //) {
    $heap->{put_count}++;
    $heap->{wheel}->put( '2: ' . $line );
  }
  elsif ($line =~ s/^2: //) {
    ok($line eq 'this is a test', "received test message");
    delete $heap->{wheel};
  }
}

sub client_tcp_got_error {
  my ($heap, $operation, $errnum, $errstr, $wheel_id) = @_[HEAP, ARG0..ARG3];

  if ($wheel_id == $heap->{socket_wheel_id}) {
    $heap->{test_five} = 0;
  }

  if ($wheel_id == $heap->{readwrite_wheel_id}) {
    $heap->{test_seven} = 0;
  }

  delete $heap->{wheel};
  warn "$operation error $errnum: $errstr";
}

sub client_tcp_got_flush {
  $_[HEAP]->{flush_count}++;
}

###############################################################################
# Start the TCP server and client.

POE::Component::Server::TCP->new(
  Port     => $tcp_server_port,
  Address  => '127.0.0.1',
  Alias    => 'tcp_server',
  Acceptor => sub {
    &sss_new(@_[ARG0..ARG2]);
    # This next badness is just for testing.
    my $sockname = $_[HEAP]->{listener}->getsockname();
    delete $_[HEAP]->{listener};

    my ($port, $addr) = sockaddr_in($sockname);
    $addr = inet_ntoa($addr);
    ok(
      ($addr eq '127.0.0.1') &&
      ($port == $tcp_server_port),
      "received connection"
    );
  },
);

POE::Session->create(
  inline_states => {
    _start     => \&client_tcp_start,
    _stop      => \&client_tcp_stop,
    got_server => \&client_tcp_connected,
    got_line   => \&client_tcp_got_line,
    got_error  => \&client_tcp_got_error,
    got_flush  => \&client_tcp_got_flush,
  }
);

### main loop

POE::Kernel->run();

1;
