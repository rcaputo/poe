#!/usr/bin/perl -w
# $Id$

# Exercises Client and Server TCP components, which exercise
# SocketFactory in AF_INET6 mode.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
use Socket;

BEGIN {
  eval 'use Socket6';
  test_setup(0, "Socket6 is needed for IPv6 tests")
    if ( length($@) or
         not exists($INC{"Socket6.pm"})
       );
  my $addr = Socket6::gethostbyname2("::1", &Socket6::AF_INET6);
  test_setup(0, "IPv6 tests require a configured localhost address ('::1')")
    unless defined $addr;
}

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Component::Client::TCP Component::Server::TCP );

my $tcp_server_port = 31909;

# Congratulations! We made it this far!
test_setup(5);
ok(1);

###############################################################################
# Start the TCP server.

POE::Component::Server::TCP->new
  ( Port               => $tcp_server_port,
    Address            => '::1',
    Domain             => AF_INET6,
    Alias              => 'server',
    ClientConnected    => \&server_got_connect,
    ClientInput        => \&server_got_input,
    ClientFlushed      => \&server_got_flush,
    ClientDisconnected => \&server_got_disconnect,
    Error              => \&server_got_error,
    ClientError        => sub { }, # Hush a warning.
  );

sub server_got_connect {
  my $heap = $_[HEAP];
  $heap->{server_test_one} = 1;
  $heap->{flush_count} = 0;
  $heap->{put_count}   = 0;
}

sub server_got_input {
  my ($heap, $line) = @_[HEAP, ARG0];
  $line =~ tr/a-zA-Z/n-za-mN-ZA-M/; # rot13
  $heap->{client}->put($line);
  $heap->{put_count}++;
}

sub server_got_flush {
  $_[HEAP]->{flush_count}++;
}

sub server_got_disconnect {
  my $heap = $_[HEAP];
  ok_if(2, $heap->{put_count} == $heap->{flush_count});
}

sub server_got_error {
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  ok(2, "# skipped: AF_INET6 probably not supported");
}

###############################################################################
# Start the TCP client.

POE::Component::Client::TCP->new
  ( RemoteAddress => '::1',
    RemotePort    => $tcp_server_port,
    Domain        => AF_INET6,
    BindAddress   => '::1',
    Connected     => \&client_got_connect,
    ServerInput   => \&client_got_input,
    ServerFlushed => \&client_got_flush,
    Disconnected  => \&client_got_disconnect,
    ConnectError  => \&client_got_connect_error,
  );

sub client_got_connect {
  my $heap = $_[HEAP];
  $heap->{flush_count} = 0;
  $heap->{put_count}   = 1;
  $heap->{server}->put( '1: this is a test' );
}

sub client_got_input {
  my ($kernel, $heap, $line) = @_[KERNEL, HEAP, ARG0];

  if ($line =~ s/^1: //) {
    $heap->{put_count}++;
    $heap->{server}->put( '2: ' . $line );
  }
  elsif ($line =~ s/^2: //) {
    &ok_if(3, $line eq 'this is a test');
    $kernel->post(server => "shutdown");
    $kernel->yield("shutdown");
  }
}

sub client_got_flush {
  $_[HEAP]->{flush_count}++;
}

sub client_got_disconnect {
  my $heap = $_[HEAP];
  ok_if(4, $heap->{put_count} == $heap->{flush_count});
}

sub client_got_connect_error {
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  ok(3, "# skipped: AF_INET6 probably not supported");
  ok(4, "# skipped: AF_INET6 probably not supported");
}

### main loop

$poe_kernel->run();

ok(5);
results;

exit;
