#!perl -w -I..
# $Id$

# This program tests POE::Filter::HTTPD by setting up a small server.
# By default, it will bind to port 80 of all addresses on the local
# machine.  If this is not desired, supply a different port number on
# the command line.  For example: ./httpd.perl 8000

# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Revised for POE 0.06 by Rocco Caputo <troc@netrus.net>

use strict;

use POE qw(Wheel::ReadWrite Driver::SysRW Filter::HTTPD Wheel::SocketFactory);

###############################################################################
# This package implements an object session that acts as the server
# side of an http connection.  It receives HTTP::Request objects and
# sends HTTP::Response objects.

package ServerSession;

use strict;
use HTTP::Response;
use POE::Session;

sub DEBUG { 1 }

#------------------------------------------------------------------------------
# Create the ServerSession, and wrap it in a POE session.

sub new {
  my ($type, $handle, $peer_addr, $peer_port) = @_;

  my $self = bless { }, $type;

  new POE::Session( $self,
                    [ qw(_start _stop receive flushed error signals) ],
                                        # ARG0, ARG1, ARG2
                    [ $handle, $peer_addr, $peer_port ]
                  );

  # This returns undef so there is no chance that the reference is
  # saved elsewhere.  Keeping extra copies of session references tends
  # to thwart proper garbage collection.

  undef;
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and start the client/server
# session.

sub _start {
  my ($kernel, $heap, $handle, $peer_addr, $peer_port) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
                                        # watch for SIGINT
  $kernel->sig('INT', 'signals');
                                        # start reading and writing
  $heap->{wheel} = new POE::Wheel::ReadWrite
    ( Handle       => $handle,                # on this handle
      Driver       => new POE::Driver::SysRW, # using sysread and syswrite
      Filter       => new POE::Filter::HTTPD, # parsing I/O as http requests
      InputState   => 'receive',        # generating this event for requests
      ErrorState   => 'error',          # generating this event for errors
      FlushedState => 'flushed',        # generating this event for all-sent
    );
                                        # save some information for the logs
  $heap->{host} = $peer_addr;
  $heap->{port} = $peer_port;

  DEBUG && print "Waiting for request from $heap->{host} : $heap->{port}\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and acknowledge that the session
# has been stopped.

sub _stop {
  my $heap = $_[HEAP];
  DEBUG && print "Client session ended with $heap->{host} : $heap->{port}\n";
}

#------------------------------------------------------------------------------
# This state is invoked whenever the ReadWrite wheel has received a
# complete HTTP request.  It is invoked with a reference to a
# corresponding HTTP::Request object.

sub receive {
  my ($heap, $request) = @_[HEAP, ARG0];

  DEBUG && print "Received a request from $heap->{host} : $heap->{port}\n";

#  print "GOT ".$request->content()."\n";
                                        # create a response for the request
  my $response = new HTTP::Response('200');
  $response->push_header('Content-type', 'text/html');
  $response->content("hello: " . $request->as_string());
                                        # queue the response for output
  $heap->{wheel}->put($response, 'HTTP');
}

#------------------------------------------------------------------------------
# This state is invoked whenever the ReadWrite wheel has encountered
# an I/O error.

sub error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  if ($errnum) {
    DEBUG && print( "Session with $heap->{host} : $heap->{port} ",
                    "encountered $operation error $errnum: $errstr\n"
                  );
  }
  else {
    DEBUG && print( "Client at $heap->{host} : $heap->{port} disconnected\n" );
  }
                                        # either way, stop this session
  delete $heap->{wheel};
}

#------------------------------------------------------------------------------
# This state is invoked whenever the ReadWrite wheel's output buffer
# has been entirely written to its filehandle.  Unless the connection
# is being kept alive, this means it is safe to shut down.

sub flushed {
  my $heap = $_[HEAP];
  DEBUG && print "Response has been sent to $heap->{host} : $heap->{port}\n";
  delete $heap->{wheel};
}

#------------------------------------------------------------------------------
# Log signals, but don't handle them.  This allows POE to stop the
# session if the signals are terminal.

sub signals {
  my ($heap, $signal_name) = @_[HEAP, ARG0];

  DEBUG && print( "Session with $heap->{host} : $heap->{port} caught SIG",
                  $signal_name, "\n"
                );
                                        # do not handle the signal
  return 0;
}

###############################################################################
# This package implements a package session that acts as a simple
# server.  It creates HTTP sessions to handle client connections.

package Server;

use strict;
use Socket;
use POE::Session;

sub DEBUG { 1 }

#------------------------------------------------------------------------------
# Start the server when POE says it's okay.

sub _start {
  my ($kernel, $heap, $port) = @_[KERNEL, HEAP, ARG0];
                                        # watch for SIGINT
  $kernel->sig('INT', 'signals');
                                        # create a socket factory
  $heap->{wheel} = new POE::Wheel::SocketFactory
    ( SocketDomain   => AF_INET,        # in the INET domain/address family
      SocketType     => SOCK_STREAM,    # create stream sockets
      SocketProtocol => 'tcp',          # using the tcp protocol
      BindAddress    => INADDR_ANY,     # bound to any interface
      BindPort       => $port,          # on this port
      ListenQueue    => 5,              # listen, with a 5-connection queue
      Reuse          => 'yes',          # and allow immediate port reuse
      SuccessState   => 'accept',       # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );

  DEBUG && print "Listening to port $port on all interfaces.\n";
}

#------------------------------------------------------------------------------
# Acknowledge that the server is being stopped.

sub _stop {
  DEBUG && print "Server stopped.\n";
}

#------------------------------------------------------------------------------
# Log errors, but don't stop the server.

sub accept_error {
  my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
  DEBUG && print "Server encountered $operation error $errnum: $errstr\n";
}

#------------------------------------------------------------------------------

sub accept {
  my ($accepted_handle, $peer_addr, $peer_port) = @_[ARG0, ARG1, ARG2];

  $peer_addr = inet_ntoa($peer_addr);
  print "Server received connection from $peer_addr : $peer_port\n";
  
  new ServerSession($accepted_handle, $peer_addr, $peer_port);
}

#------------------------------------------------------------------------------
# Log signals, but don't handle them.  This allows POE to stop the
# session if the signals are terminal.

sub signals {
  my $signal_name = $_[ARG0];

  DEBUG && print "Server caught SIG$signal_name\n";
                                        # do not handle the signal
  return 0;
}

###############################################################################
# Start the server, and process events until it's time to stop.

package main;

my $listen_port = shift(@ARGV) || 80;

new POE::Session('Server',
                 [ qw(_start accept accept_error signals) ],
                                        # ARG0
                 [ $listen_port ]
                );

$poe_kernel->run();

exit;
