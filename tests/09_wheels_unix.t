#!/usr/bin/perl -w
# $Id$

# Exercises the wheels commonly used with UNIX domain sockets.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
use Socket;

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Wheel::SocketFactory
            Wheel::ReadWrite
            Filter::Line Filter::Stream
            Driver::SysRW
          );

my $unix_server_socket = '/tmp/poe-usrv';

# Congratulations! We made it this far!
&test_setup(15);
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

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $socket,
      Driver       => POE::Driver::SysRW->new( BlockSize => 10 ),
      Filter       => POE::Filter::Line->new(),
      InputState   => 'got_line',
      ErrorState   => 'got_error',
      FlushedState => 'got_flush',
    );

  &ok_if(6, defined $heap->{wheel});

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
  my ($operation, $errnum, $errstr) = @_[ARG0..ARG2];

  &ok_unless(8, $errnum);

  delete $_[HEAP]->{wheel};
}

sub sss_flush {
  $_[HEAP]->{flush_count}++;
}

sub sss_stop {
  &ok_if (10, $_[HEAP]->{put_count} == $_[HEAP]->{flush_count});
}

###############################################################################
# A UNIX domain socket server.

sub server_unix_start {
  my $heap = $_[HEAP];

  unlink $unix_server_socket if -e $unix_server_socket;

  $heap->{wheel} = POE::Wheel::SocketFactory->new
    ( SocketDomain => PF_UNIX,
      BindAddress  => $unix_server_socket,
      SuccessState => 'got_client',
      FailureState => 'got_error',
    );

  $_[HEAP]->{client_count} = 0;

  &ok_if(2, defined $heap->{wheel});
}

sub server_unix_stop {
  delete $_[HEAP]->{wheel};

  &ok_if(11, $_[HEAP]->{client_count} == 1);

  unlink $unix_server_socket if -e $unix_server_socket;
}

sub server_unix_answered {
  &ok(5);
  $_[HEAP]->{client_count}++;
  &sss_new(@_[ARG0..ARG2]);
}

sub server_unix_error {
  warn $_[SESSION]->ID;
  # catch failed creates
}

# This arrives with 'lose' when a server session has closed.
sub server_unix_child {
  if ($_[ARG0] eq 'create') {
    $_[HEAP]->{child} = $_[ARG1];
  }
  if ($_[ARG0] eq 'lose') {
    delete $_[HEAP]->{wheel};
    &ok_if(9, $_[ARG1] == $_[HEAP]->{child});
  }
}

###############################################################################
# A UNIX domain socket client.

sub client_unix_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::SocketFactory->new
    ( SocketDomain  => PF_UNIX,
      RemoteAddress => $unix_server_socket,
      SuccessState  => 'got_server',
      FailureState  => 'got_error',
    );

  &ok_if(3, defined $heap->{wheel});
}

sub client_unix_stop {
  &ok(7);
}

sub client_unix_connected {
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

  &ok_if(4, defined $heap->{wheel});

  $heap->{flush_count} = 0;
  $heap->{put_count}   = 1;
  $heap->{wheel}->put( '1: this is a test' );

  &ok_if(14, $heap->{wheel}->get_driver_out_octets() == 19);
  &ok_if(15, $heap->{wheel}->get_driver_out_messages() == 1);
}

sub client_unix_got_line {
  my ($heap, $line) = @_[HEAP, ARG0];

  if ($line =~ s/^1: //) {
    $heap->{put_count}++;
    $heap->{wheel}->put( '2: ' . $line );
  }
  elsif ($line =~ s/^2: //) {
    &ok_if(13, $line eq 'this is a test');
    delete $heap->{wheel};
  }
}

sub client_unix_got_error {
  my ($operation, $errnum, $errstr) = @_[ARG0..ARG2];
  warn "$operation error $errnum: $errstr";
}

sub client_unix_got_flush {
  $_[HEAP]->{flush_count}++;
}

### Start the UNIX domain server and client.

POE::Session->create
  ( inline_states =>
    { _start     => \&server_unix_start,
      _stop      => \&server_unix_stop,
      _child     => \&server_unix_child,
      got_client => \&server_unix_answered,
      got_error  => \&server_unix_error,
    }
  );

POE::Session->create
  ( inline_states =>
    { _start     => \&client_unix_start,
      _stop      => \&client_unix_stop,
      got_server => \&client_unix_connected,
      got_line   => \&client_unix_got_line,
      got_error  => \&client_unix_got_error,
      got_flush  => \&client_unix_got_flush
    }
  );

### main loop

$poe_kernel->run();

&ok(12);
&results;

exit;
