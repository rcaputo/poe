#!/usr/bin/perl -w
# $Id$

# Exercises Client and Server TCP components, which exercise
# SocketFactory in AF_INET6 mode.

use strict;
use lib qw(./mylib ../mylib);
use Socket;

BEGIN {
  my $error;

  eval 'use Socket6';
  if ( length($@) or not exists($INC{"Socket6.pm"}) ) {
    $error = "Socket6 is needed for IPv6 tests";
  }
  elsif ($^O eq "cygwin") {
    $error = "IPv6 is not available on Cygwin, even if Socket6 is installed";
  }
  else {
    my $addr;
    eval { $addr = Socket6::inet_pton(&Socket6::AF_INET6, "::1") };
    if ($@) {
      $error = "AF_INET6 not provided by Socket6.pm ... can't test this";
    }
    elsif (!defined $addr) {
      $error = "IPv6 tests require a configured localhost address ('::1')";
    }
    elsif (!-f 'run_network_tests') {
      $error = "Network access (and permission) required to run this test";
    }
  }

  # Not Test::More, because I'm pretty sure skip_all calls Perl's
  # regular exit().
  if ($error) {
    print "1..0 # Skip $error\n";
    CORE::exit();
  }
}

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw( Component::Client::TCP Component::Server::TCP );

my $tcp_server_port = 31909;

# Congratulations! We made it this far!
use Test::More tests => 3;

diag( "This test may hang if your firewall blocks IPv6" );
diag( "packets across your localhost interface." );

###############################################################################
# Start the TCP server.

POE::Component::Server::TCP->new(
  Port               => $tcp_server_port,
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
  ok(
    $heap->{put_count} == $heap->{flush_count},
    "server put_count matches flush_count"
  );
}

sub server_got_error {
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  SKIP: {
    skip "AF_INET6 probably not supported ($syscall error $errno: $error)", 1
  }
}

###############################################################################
# Start the TCP client.

POE::Component::Client::TCP->new(
  RemoteAddress => '::1',
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
    ok(
      $line eq "this is a test",
      "received input"
    );
    $kernel->post(server => "shutdown");
    $kernel->yield("shutdown");
  }
}

sub client_got_flush {
  $_[HEAP]->{flush_count}++;
}

sub client_got_disconnect {
  my $heap = $_[HEAP];
  ok(
    $heap->{put_count} == $heap->{flush_count},
    "client put_count matches flush_count"
  );
}

sub client_got_connect_error {
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  SKIP: {
    skip "AF_INET6 probably not supported ($syscall error $errno: $error)", 2;
  }
}

### main loop

POE::Kernel->run();

1;
