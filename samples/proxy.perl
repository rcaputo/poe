#!/usr/bin/perl -w -I..
# $Id$

# This is a proof of concept for proxies, or other programs that
# employ both client and server sockets in the same sesion.  Previous
# incarnations of POE did not easily support proxies.

use strict;
use Socket;
use POE qw(Wheel::ListenAccept Wheel::ReadWrite Driver::SysRW Filter::Stream
           Wheel::SocketFactory
          );
                                        # serial number for logging connections
my $log_id = 0;

# Redirections are in the form:
#  listen_address:listen_port-connect_address:connect_port

my @redirects =
  qw( 127.0.0.1:7000-127.0.0.1:7001
      127.0.0.1:7001-127.0.0.1:7002
      127.0.0.1:7002-127.0.0.1:7003
      127.0.0.1:7003-127.0.0.1:7004
      127.0.0.1:7004-127.0.0.1:7005
      127.0.0.1:7005-127.0.0.1:7006
      127.0.0.1:7006-127.0.0.1:7007
      127.0.0.1:7007-127.0.0.1:7008
      127.0.0.1:7008-127.0.0.1:7009
      127.0.0.1:7009-nexi.com:daytime
      127.0.0.1:7010-127.0.0.1:7010
      127.0.0.1:7777-127.0.0.1:12345
      127.0.0.1:6667-nexi.com:1617
      127.0.0.1:8000-127.0.0.1:32000
      127.0.0.1:8888-bogusmachine.nowhere.land:80
    );

###############################################################################
# This is a stream-based proxy session.  It passes data between two
# sockets, and that's about all.

#------------------------------------------------------------------------------
# Create a proxy session to take over the connection.

sub session_create {
  my ($handle, $peer_host, $peer_port, $remote_addr, $remote_port) = @_;

  new POE::Session( _start         => \&session_start,
                    _stop          => \&session_stop,
                    client_input   => \&session_client_input,
                    client_error   => \&session_client_error,
                    server_connect => \&session_server_connect,
                    server_input   => \&session_server_input,
                    server_error   => \&session_server_error,
                                        # ARG0, ARG1, ARG2, ARG3, ARG4
                    [ $handle, $peer_host, $peer_port,
                      $remote_addr, $remote_port
                    ]
                  );
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event.  Try to establish the client
# side of the proxy session.

sub session_start {
  my ($heap, $socket, $peer_host, $peer_port, $remote_addr, $remote_port) =
    @_[HEAP, ARG0, ARG1, ARG2, ARG3, ARG4];

  $heap->{'log'} = ++$log_id;

  $peer_host = inet_ntoa($peer_host);
  print "[$heap->{'log'}] Accepted connection from $peer_host:$peer_port\n";

  $heap->{peer_host} = $peer_host;
  $heap->{peer_port} = $peer_port;
  $heap->{remote_addr} = $remote_addr;
  $heap->{remote_port} = $remote_port;

  $heap->{state} = 'connecting';
  $heap->{queue} = [];

  $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $socket,
      Driver     => new POE::Driver::SysRW,
      Filter     => new POE::Filter::Stream,
      InputState => 'client_input',
      ErrorState => 'client_error',
    );
  
  $heap->{wheel_server} = new POE::Wheel::SocketFactory
    ( SocketDomain   => AF_INET,
      SocketType     => SOCK_STREAM,
      SocketProtocol => 'tcp',
      RemoteAddress  => $remote_addr,
      RemotePort     => $remote_port,
      SuccessState   => 'server_connect',
      FailureState   => 'server_error',
    );
}

#------------------------------------------------------------------------------
# Stop the session, and remove all wheels.

sub session_stop {
  my $heap = $_[HEAP];

  print "[$heap->{'log'}] Closing redirection session\n";

  delete $heap->{wheel_client};
  delete $heap->{wheel_server};
}

#------------------------------------------------------------------------------
# Received input from the client.  Pass it to the server.

sub session_client_input {
  my ($heap, $input) = @_[HEAP, ARG0];

  if ($heap->{state} eq 'connecting') {
    push @{$heap->{queue}}, $input;
  }
  else {
    (exists $heap->{wheel_server}) && $heap->{wheel_server}->put($input);
  }
}

#------------------------------------------------------------------------------
# Received an error from the client.  Shut down the connection.

sub session_client_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  if ($errnum) {
    print( "[$heap->{'log'}] Client connection encountered ",
           "$operation error $errnum: $errstr\n"
         );
  }
  else {
    print "[$heap->{'log'}] Client closed connection.\n";
  }
                                        # stop the wheels
  delete $heap->{wheel_client};
  delete $heap->{wheel_server};
}

#------------------------------------------------------------------------------
# The connection to the server has been successfully established.
# Begin passing data through.

sub session_server_connect {
  my ($kernel, $session, $heap, $socket) = @_[KERNEL, SESSION, HEAP, ARG0];

  my ($local_port, $local_addr) = unpack_sockaddr_in(getsockname($socket));
  $local_addr = inet_ntoa($local_addr);
  print( "[$heap->{'log'}] Established forward from local ",
         "$local_addr:$local_port to remote ",
         $heap->{remote_addr}, ':', $heap->{remote_port}, "\n"
       );

  # It's important here to delete the old server wheel before creating
  # the new one.  Why?  Because otherwise the right side of the assign
  # is evaluated first.  What's this mean?  It means that the
  # ReadWrite wheel's selects get registered, and then the selects get
  # taken away when the SocketFactory is destroyed.  In a nutshell:
  # the ReadWrite never receives select events.

  delete $heap->{wheel_server};

  # It might be cleaner just to have three different wheels in this
  # session, but I originally was trying to be clever.

  $heap->{wheel_server} = new POE::Wheel::ReadWrite
    ( Handle     => $socket,
      Driver     => new POE::Driver::SysRW,
      Filter     => new POE::Filter::Stream,
      InputState => 'server_input',
      ErrorState => 'server_error',
    );

  $heap->{state} = 'connected';
  foreach my $pending (@{$heap->{queue}}) {
    $kernel->call($session, 'client_input', $pending);
  }
  $heap->{queue} = [];
}

#------------------------------------------------------------------------------
# Received input from the server.  Pass it to the client.

sub session_server_input {
  my ($heap, $input) = @_[HEAP, ARG0];

  (exists $heap->{wheel_client}) && $heap->{wheel_client}->put($input);
}

#------------------------------------------------------------------------------
# Received an error from the server.  Shut down the connection.

sub session_server_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  if ($errnum) {
    print( "[$heap->{'log'}] Server connection encountered ",
           "$operation error $errnum: $errstr\n"
         );
  }
  else {
    print "[$heap->{'log'}] Server closed connection.\n";
  }
                                        # stop the wheels
  delete $heap->{wheel_client};
  delete $heap->{wheel_server};
}

###############################################################################
# This is a stream-based proxy server.  It listens on tcp ports, and
# spawns connectors to hop down from the firewall.

sub server_create {
  my ($local_address, $local_port, $remote_address, $remote_port) = @_;

  new POE::Session( _start         => \&server_start,
                    _stop          => \&server_stop,
                    accept_success => \&server_accept_success,
                    accept_failure => \&server_accept_failure,
                                        # ARG0, ARG1, ARG2, ARG3
                    [ $local_address,  $local_port,
                      $remote_address, $remote_port
                    ]
                  );
}

#------------------------------------------------------------------------------
# Start the server.  This records where the server should connect and
# creates the listening socket.

sub server_start {
  my ($heap, $local_addr, $local_port, $remote_addr, $remote_port) =
    @_[HEAP, ARG0, ARG1, ARG2, ARG3];

  print "+ Redirecting $local_addr:$local_port to $remote_addr:$remote_port\n";
                                        # remember the redirect's details
  $heap->{local_addr}  = $local_addr;
  $heap->{local_port}  = $local_port;
  $heap->{remote_addr} = $remote_addr;
  $heap->{remote_port} = $remote_port;
                                        # create a socket factory
  $heap->{server_wheel} = new POE::Wheel::SocketFactory
    ( SocketDomain   => AF_INET,          # in the INET domain/address family
      SocketType     => SOCK_STREAM,      # create stream sockets
      SocketProtocol => 'tcp',            # using the tcp protocol
      BindAddress    => $local_addr,      # bind to this address
      BindPort       => $local_port,      # and bind to this port
      ListenQueue    => 5,                # listen, with a 5-connection queue
      Reuse          => 'yes',            # reuse immediately
      SuccessState   => 'accept_success', # generate this event on connection
      FailureState   => 'accept_failure', # generate this event on error
    );
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and log that the redirection
# server has stopped.

sub server_stop {
  my $heap = $_[HEAP];
  delete $heap->{server_wheel};
  print( "- Redirection from $heap->{local_addr}:$heap->{local_port} to ",
         "$heap->{remote_addr}:$heap->{remote_port} has stopped.\n"
       );
}

#------------------------------------------------------------------------------
# Pass the accepted socket (with peer address information) to the
# session creator, with information about where it should connect.

sub server_accept_success {
  my ($heap, $socket, $peer_addr, $peer_port) = @_[HEAP, ARG0, ARG1, ARG2];
  &session_create( $socket, $peer_addr, $peer_port,
                   $heap->{remote_addr}, $heap->{remote_port}
                 );
}

#------------------------------------------------------------------------------
# The server encountered an error.  Log it, but don't stop.

sub server_accept_failure {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  print( "! Redirection from $heap->{local_addr}:$heap->{local_port} to ",
         "$heap->{remote_addr}:$heap->{remote_port} encountered $operation ",
         "error $errnum: $errstr\n"
       );
}

###############################################################################
# Parse the redirects, and create a server session for each.

foreach my $redirect (@redirects) {
  my ($local_address, $local_port, $remote_address, $remote_port) =
    split(/[-:]+/, $redirect);

  &server_create($local_address, $local_port, $remote_address, $remote_port);
}

$poe_kernel->run();

exit;
