#!/usr/bin/perl
# $Id$
# vim: filetype=perl

use strict;
use warnings;

BEGIN {
  eval "use HTTP::Request";
  if ($@) {
    print "1..0 # skip - HTTP::Request needed to test POE::Filter::HTTPD\n";
    exit;
  }
}

#BEGIN { @INC = ('/share/immute/svn/poe/poe/lib', @INC); }
sub DEBUG () { 0 }

use POE qw/
  Component::Server::TCP
  Wheel::ReadWrite
  Wheel::SocketFactory
  Filter::HTTPD
  Filter::Stream
  /;
use HTTP::Response;
use Data::Dumper;
$Data::Dumper::Indent = 1;
use Test::More tests => 12; # FILL MEE IN!
my $PORT = '64130';

DEBUG and print "HTTPD: $POE::Filter::HTTPD::VERSION\n";
DO_TEST("Single String", [ ClientFilter => 'POE::Filter::HTTPD' ]);
DO_TEST("Single Ref",    [ ClientFilter => POE::Filter::HTTPD->new() ]);
DO_TEST("Single ArrRef", [ ClientFilter => ['POE::Filter::HTTPD'] ]);

DO_TEST("String + String", [ ClientInputFilter => 'POE::Filter::HTTPD',      ClientOutputFilter => 'POE::Filter::HTTPD'       ]);
DO_TEST("String + Ref   ", [ ClientInputFilter => 'POE::Filter::HTTPD',      ClientOutputFilter => POE::Filter::HTTPD->new()  ]);
DO_TEST("String + ArrRef", [ ClientInputFilter => 'POE::Filter::HTTPD',      ClientOutputFilter => ['POE::Filter::HTTPD']     ]);
DO_TEST("Ref + String",    [ ClientInputFilter => POE::Filter::HTTPD->new(), ClientOutputFilter => 'POE::Filter::HTTPD'       ]);
DO_TEST("Ref + Ref",       [ ClientInputFilter => POE::Filter::HTTPD->new(), ClientOutputFilter => POE::Filter::HTTPD->new()  ]);
DO_TEST("Ref + ArrRef",    [ ClientInputFilter => POE::Filter::HTTPD->new(), ClientOutputFilter => ['POE::Filter::HTTPD']     ]);
DO_TEST("ArrRef + String", [ ClientInputFilter => ['POE::Filter::HTTPD'],    ClientOutputFilter => 'POE::Filter::HTTPD'       ]);
DO_TEST("ArrRef + Ref",    [ ClientInputFilter => ['POE::Filter::HTTPD'],    ClientOutputFilter => POE::Filter::HTTPD->new()  ]);
DO_TEST("ArrRef + ArrRef", [ ClientInputFilter => ['POE::Filter::HTTPD'],    ClientOutputFilter => ['POE::Filter::HTTPD']     ]);


sub DO_TEST {
my ($TEST, $FILTER) = @_;
POE::Session->create(
  inline_states => {
    _start => sub {
        my $h = $_[HEAP];
        POE::Component::Server::TCP->new(
            Port => ($PORT),
            @$FILTER,
            ClientInput => sub {
                DEBUG and print "Got Client Input\n";
                DEBUG and print "REQUEST: ", Dumper($_[ARG0]),"\n";
                my $response = HTTP::Response->new(200);
                $response->protocol('HTTP/1.0');
                $response->push_header( 'Content-type', 'text/plain' );
                $response->content("OK\n");
                #$response = "HTTP/1.0 200 (OK)\nContent-Type: text/html\n\nOK";
                $_[HEAP]->{client}->put($response);
                $_[KERNEL]->yield('shutdown');
            },
            Started => sub { $h->{id} = $_[SESSION]->ID; DEBUG and print "Server Started\n"; },
        );
        $_[KERNEL]->delay('test_server', 1);
        $_[KERNEL]->delay('kill_server', 5);
    },
    kill_server => sub { $_[KERNEL]->post($_[HEAP]->{id}, 'shutdown'); },
    test_server => sub { 
        DEBUG and print "Creating Client Socket\n";
        my $wheel = POE::Wheel::SocketFactory->new(
            RemotePort     => $PORT,
            RemoteAddress  => '127.0.0.1',
            SuccessEvent   => "_connected",
            FailureEvent   => "_fail_connect",
        );
        $_[HEAP]->{wheel} = $wheel;        
    },
    _connected => sub {
        DEBUG and print "Creating ReadWrite\n";
        delete $_[HEAP]->{wheel};
        my $rw = POE::Wheel::ReadWrite->new(
            Handle => $_[ARG0],
            Filter => POE::Filter::Line->new(),
            InputEvent => '_got_server',
            ErrorEvent => '_rw_error',
        );
        $_[HEAP]->{rw} = $rw;
        $rw->put( "GET / HTTP/1.0\n\n");
    },
    _got_server => sub {
        if ($_[ARG0] =~ /HTTP\/\d\.\d\s+200/) { $_[HEAP]->{flag} = 1 }
    },
    _fail_connect => sub { die "Connect Failed"; },
    _rw_error     => sub {
        delete $_[HEAP]->{rw};
        ok(defined $_[HEAP]->{flag}, "Testing Filter Combo: $TEST");
    },
    
  },
);
POE::Kernel->run;
}
exit 0;
