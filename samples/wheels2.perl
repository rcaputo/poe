#!/usr/bin/perl -w -I..
# $Id$

# A simple socket client that uses a two-handle wheel to pipe between
# a socket and the console.  It's hardcoded to talk with wheels.perl's
# rot13 server on localhost port 32000.

use strict;
use POSIX;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Stream);

my $rot13_port = 32000;

#==============================================================================

sub session_start {
  my ($kernel, $heap, $connected_socket) = @_[KERNEL, HEAP, ARG0];

  print "Connecting...\n";

  $heap->{connector} = new POE::Wheel::SocketFactory
    ( RemoteAddress => '127.0.0.1',
      RemotePort => $rot13_port,
      SuccessState => 'connect_success',
      FailureState => 'connect_failure',
    );
}

sub session_connect_success {
  my ($heap, $kernel, $connected_socket) = @_[HEAP, KERNEL, ARG0];

  delete $heap->{connector};

  $heap->{console_wheel} = new POE::Wheel::ReadWrite
    ( InputHandle => \*STDIN,
      OutputHandle => \*STDOUT,
      Driver => new POE::Driver::SysRW(),
      Filter => new POE::Filter::Stream(),
      InputState => 'console_input',
      ErrorState => 'console_error',
    );

  $heap->{socket_wheel} = new POE::Wheel::ReadWrite
    ( Handle => $connected_socket,
      Driver => new POE::Driver::SysRW(),
      Filter => new POE::Filter::Stream(),
      InputState => 'socket_input',
      ErrorState => 'socket_error',
    );

  $heap->{console_wheel}->put("Begun terminal session.");
}

sub session_connect_failure {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
  if ($errnum) {
    print "!!! Connecting: $operation error $errnum: $errstr\n";
  }
  delete $heap->{connector};
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

sub session_stop {
  my $heap = $_[HEAP];
  delete $heap->{connector};
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

sub session_console_input {
  $_[HEAP]->{socket_wheel}->put($_[ARG0]);
}

sub session_console_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
  if ($errnum) {
    print "!!! Console: $operation error $errnum: $errstr\n";
  }
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

sub session_socket_input {
  $_[HEAP]->{console_wheel}->put($_[ARG0]);
}

sub session_socket_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
  if ($errnum) {
    print "!!! Socket: $operation error $errnum: $errstr\n";
  }
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

#==============================================================================

new POE::Session
  ( _start => \&session_start,
    _stop  => \&session_stop,

    connect_success => \&session_connect_success,
    connect_failure => \&session_connect_failure,

    console_input => \&session_console_input,
    console_error => \&session_console_error,

    socket_input => \&session_socket_input,
    socket_error => \&session_socket_error,
  );

$poe_kernel->run();

exit;
