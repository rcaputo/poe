#!/usr/bin/perl -w
# $Id$

# Exercises the wheels commonly used with UNIX domain sockets.

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Socket;

# We can't test_setup(0, "reason") because that calls exit().  And Tk
# will croak if you call BEGIN { exit() }.  And that croak will cause
# this test to FAIL instead of skip.
BEGIN {
  my $error;
  unless (-f 'run_network_tests') {
    $error = "Network access (and permission) required to run this test";
  }
  elsif ($^O eq "MSWin32" or $^O eq "MacOS") {
    $error = "$^O does not support UNIX sockets";
  }
  elsif ($^O eq "cygwin") {
    $error = "UNIX sockets on $^O always block";
  }

  if ($error) {
    # Not using Test::More so we can avoid Tk::exit.
    print "1..0 # Skip $error\n";
    CORE::exit();
  }
}

use Test::More tests => 12;

use POE qw(
  Wheel::SocketFactory
  Wheel::ReadWrite
  Filter::Line
  Driver::SysRW
);

my $unix_server_socket = '/tmp/poe-usrv';

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
    },
    args => [ $socket, $peer_addr, $peer_port ],
  );
}

sub sss_start {
  my ($heap, $socket, $peer_addr, $peer_port) = @_[HEAP, ARG0..ARG2];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::ReadWrite->new(
    Handle       => $socket,
    Driver       => POE::Driver::SysRW->new( BlockSize => 10 ),
    Filter       => POE::Filter::Line->new(),
    InputEvent   => 'got_line',
    ErrorEvent   => 'got_error',
    FlushedEvent => 'got_flush',
  );

  $heap->{wheel_id}    = $heap->{wheel}->ID;
  $heap->{test_six}    = 1;
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
  $heap->{test_six} = 0 if $errnum;

  delete $heap->{wheel};
}

sub sss_flush {
  $_[HEAP]->{flush_count}++;
}

sub sss_stop {
  my $heap = $_[HEAP];
  ok($heap->{test_six}, "test six");
  ok(
    $_[HEAP]->{put_count} == $_[HEAP]->{flush_count},
    "flushed everything we put"
  );
}

###############################################################################
# A UNIX domain socket server.

sub server_unix_start {
  my $heap = $_[HEAP];

  unlink $unix_server_socket if -e $unix_server_socket;

  $heap->{wheel} = POE::Wheel::SocketFactory->new(
    SocketDomain => PF_UNIX,
    BindAddress  => $unix_server_socket,
    SuccessEvent => 'got_client',
    FailureEvent => 'got_error',
  );

  $heap->{client_count} = 0;
  $heap->{test_two}     = 1;
}

sub server_unix_stop {
  my $heap = $_[HEAP];

  delete $heap->{wheel};

  ok($heap->{test_two}, "test two");
  ok($heap->{client_count} == 1, "only one client");

  unlink $unix_server_socket if -e $unix_server_socket;
}

sub server_unix_answered {
  $_[HEAP]->{client_count}++;
  sss_new(@_[ARG0..ARG2]);
}

sub server_unix_error {
  my ($session, $heap, $operation, $errnum, $errstr, $wheel_id) =
    @_[SESSION, HEAP, ARG0..ARG3];

  if ($wheel_id == $heap->{wheel}->ID) {
    delete $heap->{wheel};
    $heap->{test_two} = 0;
  }

  warn $session->ID, " got $operation error $errnum: $errstr\n";
}

# This arrives with 'lose' when a server session has closed.
sub server_unix_child {
  if ($_[ARG0] eq 'create') {
    $_[HEAP]->{child} = $_[ARG1];
  }
  if ($_[ARG0] eq 'lose') {
    delete $_[HEAP]->{wheel};
    ok(
      $_[ARG1] == $_[HEAP]->{child},
      "lost expected child session"
    );
  }
}

###############################################################################
# A UNIX domain socket client.

sub client_unix_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::SocketFactory->new(
    SocketDomain  => PF_UNIX,
    RemoteAddress => $unix_server_socket,
    SuccessEvent  => 'got_server',
    FailureEvent  => 'got_error',
  );

  $heap->{socket_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_three} = 1;
}

sub client_unix_stop {
  my $heap = $_[HEAP];
  ok($heap->{test_three}, "test three");
  ok($heap->{test_four}, "test four");
}

sub client_unix_connected {
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
  $heap->{test_four}   = 1;
  $heap->{flush_count} = 0;
  $heap->{put_count}   = 1;
  $heap->{wheel}->put( '1: this is a test' );

  ok(
    $heap->{wheel}->get_driver_out_octets() == 19,
    "buffered 19 octets"
  );
  ok(
    $heap->{wheel}->get_driver_out_messages() == 1,
    "buffered 1 message"
  );
}

sub client_unix_got_line {
  my ($heap, $line) = @_[HEAP, ARG0];

  if ($line =~ s/^1: //) {
    $heap->{put_count}++;
    $heap->{wheel}->put( '2: ' . $line );
  }
  elsif ($line =~ s/^2: //) {
    ok(
      $line eq 'this is a test',
      "received expected text"
    );
    delete $heap->{wheel};
  }
}

sub client_unix_got_error {
  my ($session, $heap, $operation, $errnum, $errstr, $wheel_id) =
    @_[SESSION, HEAP, ARG0..ARG3];

  if ($wheel_id == $heap->{socket_wheel_id}) {
    $heap->{test_three} = 0;
  }

  if ($wheel_id == $heap->{readwrite_wheel_id}) {
    $heap->{test_four} = 0;
  }

  delete $heap->{wheel};
  warn $session->ID, " caught $operation error $errnum: $errstr";
}

sub client_unix_got_flush {
  $_[HEAP]->{flush_count}++;
}

### Start the UNIX domain server and client.

POE::Session->create(
  inline_states => {
    _start     => \&server_unix_start,
    _stop      => \&server_unix_stop,
    _child     => \&server_unix_child,
    got_client => \&server_unix_answered,
    got_error  => \&server_unix_error,
  }
);

POE::Session->create(
  inline_states => {
    _start     => \&client_unix_start,
    _stop      => \&client_unix_stop,
    got_server => \&client_unix_connected,
    got_line   => \&client_unix_got_line,
    got_error  => \&client_unix_got_error,
    got_flush  => \&client_unix_got_flush
  }
);

### main loop

POE::Kernel->run();

pass("run() returned normally");

1;
