#!/usr/bin/perl -w
# $Id$

# Exercise Server::TCP and later, when it's available, Client::TCP.

use strict;
use lib qw(./lib ../lib .. .);
use TestSetup;

test_setup(18);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw( Component::Server::TCP Wheel::ReadWrite Component::Client::TCP );

# Create a server.  This one uses Acceptor to create a session of the
# program's devising.

POE::Component::Server::TCP->new
  ( Port => 31401,
    Alias => 'acceptor_server',
    Acceptor => sub {
      my ($socket, $peer_addr, $peer_port) = @_[ARG0..ARG2];
      POE::Session->create
        ( inline_states =>
          { _start => sub {
              my $heap = $_[HEAP];
              $heap->{wheel} = POE::Wheel::ReadWrite->new
                ( Handle       => $socket,
                  InputEvent   => 'got_input',
                  ErrorEvent   => 'got_error',
                  FlushedEvent => 'got_flush',
                );
              ok(1);
            },
            _stop => sub {
              ok(2);
            },
            got_input => sub {
              my ($heap, $input) = @_[HEAP, ARG0];
              ok(3);
              $heap->{wheel}->put("echo: $input");
              $heap->{shutdown} = 1 if $input eq "quit";
            },
            got_error => sub {
              my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
              print "server got $operation error $errnum: $errstr\n";
            },
            got_flush => sub {
              my $heap = $_[HEAP];
              ok(4);
              delete $heap->{wheel} if $heap->{shutdown};
            },
          },
        );
    },
  );

# Create a server.  This one uses ClientXyz to process clients instead
# of a user-defined session.

POE::Component::Server::TCP->new
  ( Port => 31402,
    Alias => 'input_server',
    ClientInput => sub {
      my ($heap, $input) = @_[HEAP, ARG0];
      ok(5);
      $heap->{client}->put("echo: $input");
      $heap->{shutdown} = 1 if $input eq "quit";
    },
    ClientError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      print "server got $operation error $errnum: $errstr\n";
      delete $heap->{client};
    },
    ClientFlushed => sub {
      ok(6);
    },
    ClientConnected => sub {
      ok(7);
    },
    ClientDisconnected => sub {
      ok(8);
    },
  );

# A client to connect to acceptor_server.

POE::Component::Client::TCP->new
  ( RemoteAddress => '127.0.0.1',
    RemotePort    => 31401,

    Connected => sub {
      ok(9);
      $_[HEAP]->{server}->put( "quit" );
    },

    ConnectError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      print "server got $operation error $errnum: $errstr\n";
    },

    Disconnected => sub {
      ok(10);
      $_[KERNEL]->post( acceptor_server => 'shutdown' );
    },

    ServerInput => sub {
      my ($heap, $input) = @_[HEAP, ARG0];
      ok(11);
    },

    ServerError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      ok(17) if $operation eq 'read' and $errnum == 0;
    },

    ServerFlushed => sub {
      ok(12);
    },
  );

# A client to connect to input_server.

POE::Component::Client::TCP->new
  ( RemoteAddress => '127.0.0.1',
    RemotePort    => 31402,

    Connected => sub {
      ok(13);
      $_[HEAP]->{server}->put( "quit" );
    },

    ConnectError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      print "client got $operation error $errnum: $errstr\n";
    },

    Disconnected => sub {
      ok(14);
      $_[KERNEL]->post( input_server => 'shutdown' );
    },

    ServerInput => sub {
      my ($heap, $input) = @_[HEAP, ARG0];
      ok(15);
    },

    ServerError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      ok(18) if $operation eq 'read' and $errnum == 0;
    },

    ServerFlushed => sub {
      ok(16);
    },
  );

# Run the tests.

$poe_kernel->run();

results();
exit 0;
