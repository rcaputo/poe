#!/usr/bin/perl -w
# $Id$

# Exercises the ListenAccept wheel.

use strict;
use lib qw(./lib ../lib);
use IO::Socket;

use TestSetup qw(ok not_ok ok_if results test_setup many_not_ok);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Session::ASSERT_STATES () { 0 }
use POE qw(Wheel::ListenAccept Wheel::SocketFactory);

&test_setup(4);

### A listening session.
sub listener_start {
  my $heap = $_[HEAP];

  my $listening_socket = IO::Socket::INET->new
    ( LocalPort => 14195,               # some random port
      Listen    => 5,
      Proto     => 'tcp',
      Reuse     => 'yes',
    );

  if (defined $listening_socket) {
    &ok(2);
  }
  else {
    &not_ok(2);
    &not_ok(3);
    return;
  }

  $heap->{listener_wheel} = POE::Wheel::ListenAccept->new
    ( Handle      => $listening_socket,
      AcceptEvent => 'got_connection_nonexistent',
      ErrorEvent  => 'got_error_nonexistent'
    );

  $heap->{listener_wheel}->event( AcceptEvent => 'got_connection',
                                  ErrorEvent  => 'got_error'
                                );

  $heap->{accept_count} = 0;
  $_[KERNEL]->delay( got_timeout => 15 );
}

sub listener_stop {
  &ok_if(3, $_[HEAP]->{accept_count} == 5);
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
  $_[HEAP]->{connector_wheel} = POE::Wheel::SocketFactory->new
    ( RemoteAddress => '127.0.0.1',
      RemotePort    => 14195,
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

&ok(1);

POE::Session->create
  ( inline_states =>
    { _start         => \&listener_start,
      _stop          => \&listener_stop,
      got_connection => \&listener_got_connection,
      got_error      => \&listener_got_error,
      got_timeout    => \&listener_got_timeout,
    }
  );

for (my $connector_count=0; $connector_count < 5; $connector_count++) {
  POE::Session->create
    ( inline_states =>
      { _start         => \&connector_start,
        got_connection => \&connector_got_connection,
        got_error      => \&connector_got_error,
      }
    );
}

$poe_kernel->run();

&ok(4);
&results();

exit;
