#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use warnings;
use strict;

BEGIN {
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
  Address      => '127.0.0.1',
  Port         => 0,
  ClientFilter => 'POE::Filter::HTTPD',
  Started => sub {
    use Socket qw(sockaddr_in);
    $port = (
      sockaddr_in($_[HEAP]->{listener}->getsockname())
    )[0];
  },

  ClientInput => sub {
    my ( $kernel, $heap, $request ) = @_[ KERNEL, HEAP, ARG0 ];
    isa_ok( $request, 'HTTP::Message', $request);
    ok( $request->uri() eq '/foo/bar', 'Double striped' );
    POE::Kernel->yield('shutdown');
  },
);

POE::Component::Client::TCP->new (
  Alias         => 'c0',
  RemoteAddress => '127.0.0.1',
  RemotePort => $port,
  ServerInput => sub { fail("client c0 got input from server: $_[ARG0]"); },

  # Silence errors.
  ServerError => sub { undef },
);

POE::Component::Client::TCP->new (
  Alias         => 'c1',
  RemoteAddress => '127.0.0.1',
  RemotePort => $port,
  Connected => sub {
    ok 1, 'client connected';
    $_[HEAP]->{server}->put( "GET //foo/bar 1.0\015\012\015\012");
  },
  Disconnected => sub {
    # Shutdown step 2: Kill the server and all remaining connections
    note "client c1 disconnected";
    POE::Kernel->signal( s0 => 'KILL' );
  },
  ServerInput => sub { fail("client c1 got input from server: $_[ARG0]"); },

  # Silence errors.
  ServerError => sub { undef },
);

$poe_kernel->run();
exit 0;
