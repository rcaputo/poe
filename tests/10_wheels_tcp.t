#!/usr/bin/perl -w
# $Id$

# Exercises the wheels commonly used with TCP sockets.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
use Socket;

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Component::Server::TCP
            Wheel::ReadWrite
            Filter::Line
            Driver::SysRW
          );

my $tcp_server_port = 31909;

# Congratulations! We made it this far!
&test_setup(12);
&ok(1);

###############################################################################
# A generic server session.

sub sss_new {
  my ($socket, $peer_addr, $peer_port) = @_;
  POE::Session->create
    ( inline_states =>
      { _start    => \&sss_start,
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

  # Swap the SocketFactory for the ReadWrite.  This exercises a subtle
  # bug in SocketFactory which should now be fixed.
  $heap->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $socket,
      Driver       => POE::Driver::SysRW->new( BlockSize => 10 ),
      Filter       => POE::Filter::Line->new(),
      InputState   => 'got_line',
      ErrorState   => 'got_error',
      FlushedState => 'got_flush',
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

  if ($errnum) {
    $heap->{test_two} = 0;
    &not_ok(3);
  }
  else {
    &ok(3);
  }

  delete $heap->{wheel};
}

sub sss_flush {
  $_[HEAP]->{flush_count}++;
}

sub sss_stop {
  &ok_if(2, $_[HEAP]->{test_two});
  &ok_if(4, $_[HEAP]->{put_count} == $_[HEAP]->{flush_count});
}

###############################################################################
# A TCP socket client.

sub client_tcp_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::SocketFactory->new
    ( RemoteAddress  => '127.0.0.1',
      RemotePort    => $tcp_server_port,
      SuccessState  => 'got_server',
      FailureState  => 'got_error',
    );

  $heap->{socket_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_five} = 1;
}

sub client_tcp_stop {
  &ok_if(5, $_[HEAP]->{test_five});
  &ok(6);
  &ok_if(7, $_[HEAP]->{test_seven});
}

sub client_tcp_connected {
  my ($heap, $server_socket) = @_[HEAP, ARG0];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $server_socket,
      Driver       => POE::Driver::SysRW->new( BlockSize => 10 ),
      Filter       => POE::Filter::Line->new(),
      InputState   => 'got_line',
      ErrorState   => 'got_error',
      FlushedState => 'got_flush',
    );

  $heap->{readwrite_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_seven} = 1;

  $heap->{flush_count} = 0;
  $heap->{put_count}   = 1;
  $heap->{wheel}->put( '1: this is a test' );

  &ok_if(11, $heap->{wheel}->get_driver_out_octets() == 19);
  &ok_if(12, $heap->{wheel}->get_driver_out_messages() == 1);
}

sub client_tcp_got_line {
  my ($heap, $line) = @_[HEAP, ARG0];

  if ($line =~ s/^1: //) {
    $heap->{put_count}++;
    $heap->{wheel}->put( '2: ' . $line );
  }
  elsif ($line =~ s/^2: //) {
    &ok_if(8, $line eq 'this is a test');
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

POE::Component::Server::TCP->new
  ( Port     => $tcp_server_port,
    Acceptor => sub { &sss_new(@_[ARG0..ARG2]);
                      # This next badness is just for testing.
                      my $sockname = $_[HEAP]->{listener}->getsockname();
                      delete $_[HEAP]->{listener};

                      my ($port, $addr) = sockaddr_in($sockname);
                      $addr = inet_ntoa($addr);
                      &ok_if( 10,
                              ($addr eq '0.0.0.0') &&
                              ($port == $tcp_server_port)
                            )
                    },
  );

POE::Session->create
  ( inline_states =>
    { _start     => \&client_tcp_start,
      _stop      => \&client_tcp_stop,
      got_server => \&client_tcp_connected,
      got_line   => \&client_tcp_got_line,
      got_error  => \&client_tcp_got_error,
      got_flush  => \&client_tcp_got_flush
    }
  );

### main loop

$poe_kernel->run();

&ok(9);
&results;

exit;
