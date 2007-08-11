#!/usr/bin/perl -w
# $Id$

# Exercise Server::TCP and later, when it's available, Client::TCP.

use strict;
use lib qw(./mylib ../mylib);

BEGIN {
  unless (-f "run_network_tests") {
    print "1..0 # Skip Network access (and permission) required to run this test\n";
    CORE::exit();
  }
}

use Test::More tests => 30;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw( Component::Server::TCP Wheel::ReadWrite Component::Client::TCP );

my ($acceptor_port, $callback_port);

# Create a server.  This one uses Acceptor to create a session of the
# program's devising.

POE::Component::Server::TCP->new(
  Port => 0,
  Alias => 'acceptor_server',
  Started => sub {
    use Socket qw(sockaddr_in);
    $acceptor_port = (
      sockaddr_in($_[HEAP]->{listener}->getsockname())
    )[0];
  },
  Acceptor => sub {
    my ($socket, $peer_addr, $peer_port) = @_[ARG0..ARG2];
    POE::Session->create(
      inline_states => {
        _start => sub {
          my $heap = $_[HEAP];
          $heap->{wheel} = POE::Wheel::ReadWrite->new(
            Handle       => $socket,
            InputEvent   => 'got_input',
            ErrorEvent   => 'got_error',
            FlushedEvent => 'got_flush',
          );
          pass("acceptor server got client connection");
        },
        _stop => sub {
          pass("acceptor server stopped the client session");
        },
        got_input => sub {
          my ($heap, $input) = @_[HEAP, ARG0];
          pass("acceptor server received input");
          $heap->{wheel}->put("echo: $input");
          $heap->{shutdown} = 1 if $input eq "quit";
        },
        got_error => sub {
          my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
          print "acceptor server got $operation error $errnum: $errstr\n";
        },
        got_flush => sub {
          my $heap = $_[HEAP];
          pass("acceptor server flushed output");
          delete $heap->{wheel} if $heap->{shutdown};
        },
      },
    );
  },
);

# Create a server.  This one uses ClientXyz to process clients instead
# of a user-defined session.

POE::Component::Server::TCP->new(
  Port => 0,
  Alias => 'input_server',
  ClientFilter => [ "POE::Filter::Line", Literal => "\n" ],
  Started => sub {
    use Socket qw(sockaddr_in);
    $callback_port = (
      sockaddr_in($_[HEAP]->{listener}->getsockname())
    )[0];
  },
  ClientInput => sub {
    my ($heap, $input) = @_[HEAP, ARG0];
    pass("callback server got input");
    $heap->{client}->put("echo: $input");
    $heap->{shutdown} = 1 if $input eq "quit";
  },
  ClientError => sub {
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
    print "callback server got $operation error $errnum: $errstr\n";
  },
  ClientFlushed => sub {
    pass("callback server flushed output");
  },
  ClientConnected => sub {
    pass("callback server got client connection");
  },
  ClientDisconnected => sub {
    pass("callback server got client disconnected");
  },
);

# Test that the constructor of PoCo::Client::TCP is strict in what it
# accepts as valid arguments
{
  eval { POE::Component::Client::TCP->new(
    RemoteAddress => "1.2.3.4", Odd => "Elephant", "Of Arguments") };
  ok($@ =~ /odd|even/,
    "Client::TCP constructor requires even number of parameters");

  my %base_args = (
    RemoteAddress => '127.0.0.1',
    RemotePort => 31401,
    Connected => sub { },
    ConnectError => sub { },
    Disconnected => sub { },
    ServerInput => sub { },
    ServerError => sub { },
    ServerFlushed => sub { },
  );
  my $test_missing = sub {
    my ($args, $remove) = @_;
    delete $$args{$_} for @$remove;
    eval { POE::Component::Client::TCP->new( %$args ) };
    ok($@ ne '', "Client::TCP constructor requires " . join(", ", @$remove));
  };
  $test_missing->({%base_args}, ["RemoteAddress"]);
  $test_missing->({%base_args}, ["RemotePort"]);
  $test_missing->({%base_args}, ["ServerInput"]);
  my %mark_args = (%base_args,
    HighMark => 256, LowMark => 64,
    ServerHigh => sub { }, ServerLow => sub { }
  );
  $test_missing->({%mark_args}, ["LowMark", "ServerHigh", "ServerLow"]);
  $test_missing->({%mark_args}, ["HighMark", "ServerHigh", "ServerLow"]);
  $test_missing->({%mark_args}, ["HighMark", "LowMark", "ServerLow"]);
  $test_missing->({%mark_args}, ["HighMark", "LowMark", "ServerHigh"]);

  my $test_notref = sub {
    my $which = shift;
    eval { POE::Component::Client::TCP->new( %base_args,
        $which => "Not a reference" ) };
    ok($@ =~ /$which.*reference/i,
      "Client::TCP constructor requires $which to be a reference");
  };
  $test_notref->("InlineStates");
  $test_notref->("PackageStates");
  $test_notref->("ObjectStates");

  eval { POE::Component::Client::TCP->new( %base_args,
      SessionParams => sub { "Not an array reference" }) };
  ok($@ =~ /SessionParams/,
    "Client::TCP constructor requires SessionParams to be an array reference");
}

# A client to connect to acceptor_server.

POE::Component::Client::TCP->new(
  RemoteAddress => '127.0.0.1',
  RemotePort    => $acceptor_port,

  Connected => sub {
    pass("acceptor client connected");
    $_[HEAP]->{server}->put( "quit" );
  },

  ConnectError => sub {
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
    print "acceptor client got $operation error $errnum: $errstr\n";
  },

  Disconnected => sub {
    pass("acceptor client disconnected");
    $_[KERNEL]->post( acceptor_server => 'shutdown' );
  },

  ServerInput => sub {
    my ($heap, $input) = @_[HEAP, ARG0];
    pass("acceptor client got input");
  },

  ServerError => sub {
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
    ok(
      ($operation eq "read") && ($errnum == 0),
      "acceptor client got read error 0 (EOF)"
    );
  },

  ServerFlushed => sub {
    pass("acceptor client flushed output");
  },
);

# A client to connect to input_server.

POE::Component::Client::TCP->new(
  RemoteAddress => '127.0.0.1',
  RemotePort    => $callback_port,
  Filter => [ "POE::Filter::Line", Literal => "\n" ],

  Connected => sub {
    pass("callback client connected");
    $_[HEAP]->{server}->put( "quit" );
  },

  ConnectError => sub {
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
    print "callback client got $operation error $errnum: $errstr\n";
  },

  Disconnected => sub {
    pass("callback client disconnected");
    $_[KERNEL]->post( input_server => 'shutdown' );
  },

  ServerInput => sub {
    my ($heap, $input) = @_[HEAP, ARG0];
    pass("callback client got input");
  },

  ServerError => sub {
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
    ok(
      ($operation eq "read") && ($errnum == 0),
      "callback client got read error 0 (EOF)"
    );
  },

  ServerFlushed => sub {
    pass("callback client flushed output");
  },
);

# Run the tests.

POE::Kernel->run();

1;
