#!/usr/bin/perl
# vim: filetype=perl ts=2 sw=2 expandtab

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

use Test::More tests => 2;

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

  ClientInput => sub {
    my ( $kernel, $heap, $request ) = @_[ KERNEL, HEAP, ARG0 ];
    isa_ok( $request, 'HTTP::Message', $request);
  },
);

POE::Component::Client::TCP->new (
  Alias => 'c0',
  RemoteAddress => '127.0.0.1',
  RemotePort => $port,
  ServerInput => sub {
    diag("Server Input: $_[ARG0]");
  }
);

POE::Component::Client::TCP->new (
  Alias => 'c1',
  RemoteAddress => '127.0.0.1',
  RemotePort => $port,
  Connected => sub {
    ok 1, 'client connected';
    $_[HEAP]->{server}->put( "GET / 1.0\015\012\015\012");
  },
  ServerInput => sub {
    ok 1, "client got $_[ARG0]";
  }
);

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->delay_add( done => 3 );
    },
    done => sub {
      $_[KERNEL]->post( $_ => 'shutdown' )
        for qw/ s0 c0 c1 /;
    }
  }
);

$poe_kernel->run();
exit 0;
