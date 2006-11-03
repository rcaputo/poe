#!/usr/bin/perl
# $Id$
# vim: filetype=perl

use warnings;
use strict;

BEGIN {
  eval "use HTTP::Request";
  if ($@) {
    print "1..0 # skip - HTTP::Request needed to test POE::Filter::HTTPD\n";
    exit;
  }
}

use Test::More tests => 2;

use constant PORT => 31416;

use POE qw(
  Component::Client::TCP
  Component::Server::TCP
  Filter::HTTPD
);

#
# handler
#

POE::Component::Server::TCP->new(
  Port         => PORT,
  ClientFilter => 'POE::Filter::HTTPD',

  ClientInput => sub {
    my ( $kernel, $heap, $request ) = @_[ KERNEL, HEAP, ARG0 ];
    isa_ok( $request, 'HTTP::Message', $request);
  },
);

POE::Component::Client::TCP->new (
  RemoteAddress => '127.0.0.1',
  RemotePort => PORT,
  ServerInput => sub {
    diag("Server Input: $_[ARG0]");
  }
);

POE::Component::Client::TCP->new (
  RemoteAddress => '127.0.0.1',
  RemotePort => PORT,
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
      exit 1;
    }
  }
);

$poe_kernel->run();
exit 0;
