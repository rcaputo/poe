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
  if ($^O eq "MSWin32") {
    print "1..0 # Skip Windows sockets aren't as concurrent as those on Unix\n";
    CORE::exit();
  }
}

use Test::More tests => (42);

diag( "You might see a 'disconnect' error during this test." );
diag( "It may be ignored." );

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
# sub POE::Kernel::TRACE_EVENTS  () { 1 }
# sub POE::Kernel::TRACE_FILES  () { 1 }
# sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw( Component::Server::TCP Wheel::ReadWrite Component::Client::TCP );

#use POE::API::Peek;

my ($acceptor_port, $callback_port);

sub DEBUG () { 0 }

do_servers();
do_clients();

# Run the tests.

POE::Kernel->run();

sub do_servers {
  my($acceptorN, $callbackN)=(0,0);

  my(%connected);

  ######################################################################
  # Create a server.  This one uses Acceptor to create a session of the
  # program's devising.
  POE::Component::Server::TCP->new(
    Port => 0,
    Alias => 'acceptor_server',
    Concurrency => 1,
    Started => sub {
      use Socket qw(sockaddr_in);
      $acceptor_port = (
        sockaddr_in($_[HEAP]->{listener}->getsockname())
      )[0];
    },
    Acceptor => sub {
      my ($socket, $peer_addr, $peer_port) = @_[ARG0..ARG2];

      if( $connected{acceptor} ) {
        fail("acceptor server got simultaneous connections");
      }
      else {
        pass("acceptor server : one connection open");
      }
      $connected{acceptor} = 1;

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
            $heap->{tcp_server} = $_[SENDER]->ID;
            DEBUG and warn("$$: acceptor server got client connection");
          },
          _stop => sub {
            DEBUG and warn("$$: acceptor server stopped the client session");
            $connected{acceptor} = 0;
          },
          got_input => sub {
            my ($heap, $input) = @_[HEAP, ARG0];
            $acceptorN++;
            DEBUG and warn(
              "$$: acceptor server received input ($input) ",
              "acceptorN=$acceptorN"
            );
            $heap->{wheel}->put("echo: $input #$acceptorN");
            if($input eq "quit") {
              DEBUG and warn("$$: accept_server quit");
              $heap->{shutdown} = 1;
              $_[KERNEL]->post( $heap->{tcp_server} => 'shutdown' );
            }
          },
          got_error => sub {
            my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
            if($operation eq 'read' and $errnum==0) {
              DEBUG and warn("$$: acceptor server disconnect error");
              $heap->{shutdown} = 1;
              $_[KERNEL]->post( $heap->{tcp_server} => 'disconnected' );
            }
            else {
              warn(
                "$$: acceptor server got $operation error $errnum: $errstr\n"
              );
            }
            delete $heap->{wheel};
          },
          got_flush => sub {
            my $heap = $_[HEAP];
            DEBUG and warn("$$: acceptor server flushed output");
            if($heap->{shutdown}) {
              delete $heap->{wheel};
              DEBUG and warn "$$: acceptor server disconnected";
              $_[KERNEL]->post( $heap->{tcp_server} => 'disconnected' );
            }
          },
        },
      );
    },
  );


  ######################################################################
  # Create a server.  This one uses ClientXyz to process clients instead
  # of a user-defined session.
  POE::Component::Server::TCP->new(
    Port => 0,
    Alias => 'callback_server',
    Started => sub {
      use Socket qw(sockaddr_in);
      $callback_port = (
        sockaddr_in($_[HEAP]->{listener}->getsockname())
      )[0];
    },
    Concurrency => 4,
    # ClientShutdownOnError => 0,

    ClientInput => sub {
      my ($heap, $input) = @_[HEAP, ARG0];
      $callbackN++;
      DEBUG and warn(
        "$$: callback server received input ($input) callbackN=$callbackN"
      );
      if($input eq "quit") {
        DEBUG and warn("$$: callback_server quit");
        $_[KERNEL]->post( callback_server => 'shutdown' );
      }
      else {
        $heap->{client}->put("echo: $input #$callbackN");
      }
    },
    ClientError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      unless( $operation eq 'read' and $errnum == 0 ) {
        warn "$$: callback server got $operation error $errnum: $errstr\n";
      }
      $_[KERNEL]->yield('shutdown');
    },
    ClientFlushed => sub {
      DEBUG and warn("$$: callback server flushed output");
    },
    ClientConnected => sub {
      $connected{callback} ++;
      if( $connected{callback} > 4 ) {
        fail(
          "callback server got $connected{callback} simultaneous connections"
        );
      }
      else {
        pass("callback server : $connected{callback} connections open");
      }

      DEBUG and
        warn("$$: callback server got client connection");
    },
    ClientDisconnected => sub {
      DEBUG and
        warn("$$: callback server got client disconnected");
      $connected{callback} --;
    },
  );
}

sub do_clients {
  foreach my $N (1..21) {
    DEBUG and warn "$$: SPAWN\n";
    two_clients($N);
  }
}

sub two_clients {
  my($N) = @_;

  my $parent=0;

  ######################################################################
  # A client to connect to acceptor_server.
  POE::Component::Client::TCP->new(
    RemoteAddress => '127.0.0.1',
    RemotePort    => $acceptor_port,
    Alias         => "acceptor client $N",

    Connected => sub {
      DEBUG and warn("$$: acceptor client $N connected");
      $_[HEAP]->{server}->put( "hello $N" );
    },

    ConnectError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      warn "$$: acceptor client $N got $operation error $errnum: $errstr\n";
    },

    Disconnected => sub {
      DEBUG and warn("$$: acceptor client $N disconnected");
    },

    ServerInput => sub {
      my ($heap, $input) = @_[HEAP, ARG0];
      DEBUG and warn("$$: acceptor client $N got input ($input)");
      if( $input =~ /#21$/ ) {
        $_[HEAP]->{server}->put( 'quit' );
      }

      $_[KERNEL]->yield('shutdown');
    },

    ServerError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      ok(
        ($operation eq "read") && ($errnum == 0),
        "acceptor client $N got read error 0 (EOF)"
      );
    },

    ServerFlushed => sub {
      DEBUG and warn("$$: acceptor client $N flushed output");
    },
  );

  ######################################################################
  # A client to connect to callback_server.

  POE::Component::Client::TCP->new(
    RemoteAddress => '127.0.0.1',
    RemotePort    => $callback_port,
    Alias         => "callback client $N",

    Connected => sub {
      DEBUG and warn("$$: callback client $N connected");
      $_[HEAP]->{server}->put( "hello $N" );
    },

    ConnectError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      warn "$$: callback client $N got $operation error $errnum: $errstr\n";
    },

    Disconnected => sub {
      DEBUG and warn("$$: callback client $N disconnected");
    },

    ServerInput => sub {
      my ($heap, $input) = @_[HEAP, ARG0];
      DEBUG and warn("$$: callback client $N got input ($input)");
      if( $input =~ /#21$/ ) {
          $_[HEAP]->{server}->put( 'quit' );
      }
      $_[KERNEL]->yield('shutdown');
    },

    ServerError => sub {
      my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
      ok(
        ($operation eq "read") && ($errnum == 0),
        "callback client $N got $operation error $errnum (EOF)"
      );
    },

    ServerFlushed => sub {
      DEBUG and warn("$$: callback client $N flushed output");
    },
  );
}

1;
