#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use warnings;
use strict;

BEGIN {
  unless (-f 'run_network_tests') {
    print "1..0 # skip - Network access (and permission) required to run this test\n";
    exit;
  }
  eval "use HTTP::Request";
  if ($@) {
    print "1..0 # skip - HTTP::Request needed to test POE::Filter::HTTPD\n";
    exit;
  }
}

use Test::More tests => 3;

my $port;

use POE qw(
  Component::Client::TCP
  Component::Server::TCP
  Filter::HTTPD
);

#
# handler
#

POE::Component::Server::TCP->new(
  Alias        => 's0',
  Port         => 0,
  Address      => '127.0.0.1',
  ClientFilter => 'POE::Filter::HTTPD',
  Started => sub {
    use Socket qw(sockaddr_in);
    $port = (
      sockaddr_in($_[HEAP]->{listener}->getsockname())
    )[0];
  },
  Stopped => sub { note "server s0 stopped"; },
  ClientInput => sub {
    # Shutdown step 1: Close client c1's connection after receiving input.
    my ( $kernel, $heap, $request ) = @_[ KERNEL, HEAP, ARG0 ];
    isa_ok( $request, 'HTTP::Message', "server s0 request $request");
    POE::Kernel->yield( 'shutdown' );
  },
);

POE::Component::Client::TCP->new (
  Alias => 'c0',
  RemoteAddress => '127.0.0.1',
  RemotePort => $port,
  ServerInput => sub { fail("client c0 got input from server s0: $_[ARG0]") },
  Connected => sub { note "client c0 connected"; },
  Disconnected => sub {
    ok( 3, "client c0 disconnected" );
    POE::Kernel->post( c0 => 'shutdown' );
  },
  # Silence errors.
  ServerError => sub { undef },
);

POE::Component::Client::TCP->new (
  Alias => 'c1',
  RemoteAddress => '127.0.0.1',
  RemotePort => $port,
  ServerInput => sub { fail("client c1 got input from server s0: $_[ARG0]") },
  Connected => sub {
    ok 1, 'client c1 connected';
    $_[HEAP]->{server}->put( "GET / 1.0\015\012\015\012");
  },
  Disconnected => sub {
    # Shutdown step 2: Kill the server and all remaining connections
    note "client c1 disconnected";
    POE::Kernel->signal( s0 => 'KILL' );
  },
  # Silence errors.
  ServerError => sub { undef },
);

$poe_kernel->run();
exit 0;
