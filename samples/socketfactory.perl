#!/usr/bin/perl -w
# $Id$

# This program tests POE::Wheel::SocketFactory.  Basically, it is
# thrash.perl, but for AF_UNIX, AF_INET tcp, and AF_INET udp sockets.

use strict;
use lib '..';

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);

#------------------------------------------------------------------------------

my $unix_server = '/tmp/poe-usrv';
my $unix_client = '/tmp/poe-';
my $unix_client_count = '0000';

###############################################################################
# This package defines a generic server session to handle stream
# connections.  It was placed in a separate package because both
# AF_UNIX and AF_INET/tcp servers can use it.  And so they do.

package StreamServerSession;

use strict;
use Socket;
use POE::Session;

#------------------------------------------------------------------------------
# A regular Perl object method.  It creates a StreamServerSession
# instance, and gives it to POE to manage as a session.

sub new {
  my ($type, $socket, $peer_addr, $peer_port) = @_;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self,
                    [ '_start', '_stop', 'got_line', 'got_error', 'flushed' ],
                                        # ARG0, ARG1, ARG2
                    [ $socket, $peer_addr, $peer_port ]
                  );
  undef;
}

#------------------------------------------------------------------------------
# Log that the object has been destroyed.  This will occur after the
# session stops and releases the object's reference.

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and start the stream session.

sub _start {
  my ($object, $heap, $session, $socket, $peer_addr, $peer_port) =
    @_[OBJECT, HEAP, SESSION, ARG0, ARG1, ARG2];

  print "$object received _start.  Hi!\n";
                                        # start the read/write wheel
  $heap->{'wheel'} = new POE::Wheel::ReadWrite
    ( Handle       => $socket,                  # on this socket handle
      Driver       => new POE::Driver::SysRW(), # using sysread and syswrite
      Filter       => new POE::Filter::Line(),  # and parsing streams as lines
      InputState   => 'got_line',   # generate this event upon receipt of input
      ErrorState   => 'got_error',  # and this event if an error occurs
      FlushedState => 'flushed'     # and this event when all output is sent
    );
                                        # keep state for a high-level protocol
  $heap->{'protocol state'} = 'running';

  # Greet the client over the socket.  The peer address and port are
  # undefined for Unix sockets.

  $peer_addr = (defined $peer_addr) ? (' ' . inet_ntoa($peer_addr)) : '';
  $peer_port = (defined $peer_port) ? (' ' . $peer_port) : '';

  $heap->{'wheel'}->put("Greetings$peer_addr$peer_port");
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and clean up the session.

sub _stop {
  my $object = $_[OBJECT];
  print "$object received _stop.\n";
}

#------------------------------------------------------------------------------
# Process a line of input.

sub got_line {
  my ($object, $heap, $line) = @_[OBJECT, HEAP, ARG0];
                                        # ignore input on lingering socket
  if ($heap->{'protocol state'} eq 'quitting') {
    return;
  }

  print "$object received a command: $line\n";
                                        # rot-13 input
  if ($line =~ /^\s*rot13\s+(.*?)\s*$/i) {
    $line = $1;
    $line =~ tr/a-zA-Z/n-za-mN-ZA-M/;
    $heap->{'wheel'}->put($line);
    return;
  }
                                        # display GMT daytime
  if ($line =~ /^\s*time\s*$/i) {
    $heap->{'wheel'}->put(scalar gmtime);
    return;
  }
                                        # quit nicely, please
  if ($line =~ /^\s*quit\s*/i) {
    $heap->{'protocol state'} = 'quitting';
    $heap->{'wheel'}->put("Bye!");
    return;
  }
}

#------------------------------------------------------------------------------
# Handle I/O errors.

sub got_error {
  my ($object, $heap, $operation, $errnum, $errstr) = 
    @_[OBJECT, HEAP, ARG0, ARG1, ARG2];

  print "$object detected $operation error $errnum: $errstr\n";

  # The SocketFactory wheel is the only thing keeping this session
  # alive.  Deleting it causes its destructor to be called.  The
  # session has nothing further to do after the socketfactory is
  # destroyed, so the kernel stops it.

  delete $heap->{'wheel'};
}

#------------------------------------------------------------------------------
# When all output is flushed, check to see if the client requested a
# quit.  If they did, honor it.

sub flushed {
  my $heap = $_[HEAP];

  # Deletes the read/write wheel, causing the session to stop out of
  # boredom.

  if ($heap->{'protocol state'} eq 'quitting') {
    delete $heap->{'wheel'};
  }
}

###############################################################################
# This package defines a generic client session to request some
# services from the generic stream server connection handler.

package StreamClientSession;

use strict;
use POE::Session;

#------------------------------------------------------------------------------
# Create a Perl object, and give it to POE to manage as a session.

sub new {
  my ($type, $socket, $addr, $port) = @_;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self, [ '_start', '_stop', 'got_response', 'got_error' ],
                                        # ARG0
                    [ $socket, $addr, $port ]
                  );
  undef;
}

#------------------------------------------------------------------------------
# Log that the object has been destroyed.

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and start the stream session.

sub _start {
  my ($object, $heap, $socket) = @_[OBJECT, HEAP, ARG0];
                                        # start the read/write wheel
  $heap->{'wheel'} = new POE::Wheel::ReadWrite
    ( Handle     => $socket,                # on this socket handle
      Driver     => new POE::Driver::SysRW, # using sysread and syswrite
      Filter     => new POE::Filter::Line,  # and parsing streams as lines
      InputState => 'got_response',         # generate this event upon input
      ErrorState => 'got_error'             # and this event in an error occurs
    );
                                        # set up a query queue
  $heap->{'commands'} =
    [ 'rot13 This is a test.',
      'rot13 Guvf vf n grfg.',
      'time',
      'quit'
    ];
}

#------------------------------------------------------------------------------
# Accepts POE's standard _stop event, and clean up the session.

sub _stop {
  my $object = $_[OBJECT];
  print "$object _stop.\n";
}

#------------------------------------------------------------------------------
# Process a line of input.  Input is comprised of lines of server
# response.

sub got_response {
  my ($object, $heap, $line) = @_[OBJECT, HEAP, ARG0];
                                        # display the server's response
  print "$object got a response: $line\n";
                                        # send the next query, if one exists
  if (@{$heap->{'commands'}}) {
    $heap->{'wheel'}->put(shift @{$heap->{'commands'}});
  }
}

#------------------------------------------------------------------------------
# Handle an I/O error by disconnecting.

sub got_error {
  my ($object, $heap, $operation, $errnum, $errstr) =
    @_[OBJECT, HEAP, ARG0, ARG1, ARG2];
                                        # non-zero errnum is an error
  if ($errnum) {
    print "$object detected $operation error $errnum: $errstr\n";
  }
                                        # zero errnum is a plain disconnect
  else {
    print "$object detected a remote disconnect.\n";
  }
                                        # either way, disconnect
  delete $heap->{'wheel'};
}

###############################################################################
# This package defines a generic UNIX stream server.  It can be used
# with any stream server back-end (see StreamServerSession).

package UnixServer;

use strict;
use Socket;
use POE::Session;

#------------------------------------------------------------------------------
# Create the UnixServer object, and give it to POE to manage as a
# session.

sub new {
  my $type = shift;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self,
                    [ '_start', '_stop', 'got_client', 'got_error' ]
                  );
  undef;
}

#------------------------------------------------------------------------------
# Log that the object has been destroyed.  This will occur after the
# session stops and releases the object's reference.

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event by creating a listening socket in
# the Unix domain.

sub _start {
  my ($object, $heap) = @_[OBJECT, HEAP];

  print "$object received _start.  Hi!\n";
                                        # unlink the file, just in case
  unlink $unix_server;
                                        # start a socket factory
  $heap->{'wheel'} = new POE::Wheel::SocketFactory
    ( SocketDomain => AF_UNIX,          # in the Unix address family
      BindAddress  => $unix_server,     # bound to this Unix address
      SuccessState => 'got_client',     # sending this message when connected
      FailureState => 'got_error',      # sending this message upon failure
    );

  my $bind_path = unpack_sockaddr_un($heap->{wheel}->getsockname());
  print "********** $object wheel is bound to: $bind_path\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and clean up the session.

sub _stop {
  my ($object, $heap) = @_[OBJECT, HEAP];
  print "$object received _stop.\n";
                                        # close the socket
  delete $heap->{wheel};
                                        # unlink the socket
  if (-e $unix_server) {
    unlink($unix_server)
      or warn "could not unlink $unix_server: $!";
  }
}

#------------------------------------------------------------------------------
# Process an incoming connection.  This just spawns off a session to
# process requests.  Note that $peer_addr and $peer_port are undef for
# AF_UNIX sockets.

sub got_client {
  my ($object, $socket, $peer_addr, $peer_port) = @_[OBJECT, ARG0, ARG1, ARG2];
  print "$object received a connection.\n";
                                        # spawn the server session
  new StreamServerSession($socket, $peer_addr, $peer_port);
}

#------------------------------------------------------------------------------
# Process an error.  This could shut down the server, but it won't.

sub got_error {
  my ($object, $operation, $errnum, $errstr) = @_[OBJECT, ARG0, ARG1, ARG2];
  print "$object detected $operation error $errnum: $errstr\n";
}
###############################################################################
# This package defines a generic UNIX stream client.  It can be used
# with any stream client back-end (see StreamClientSession).

package UnixClient;

use strict;
use Socket;
use POE::Session;

#------------------------------------------------------------------------------
# This helper generates a new client socket bind address.

sub get_next_client_address {
  my $next_client;
  my $bailout = 0;
  do {
    $bailout++;
    die "all sockets busy" if ($bailout > 10000);
    $next_client = $unix_client . $unix_client_count++;
    if ($unix_client_count > 9999) {
      $unix_client_count = '0000';
    }
  } until (!-e $next_client);
}

#------------------------------------------------------------------------------
# This Perl object method creates a new UnixClient object and gives it
# to POE to manage as a session.

sub new {
  my $type = shift;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self,
                    [ '_start', '_stop', 'got_connection', 'got_error' ]
                  );
  undef;
}

#------------------------------------------------------------------------------
# Log that the object has been destroyed.  This will occur after the
# session stops and releases the object's reference.

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and start the Unix socket
# client.

sub _start {
  my ($object, $heap) = @_[OBJECT, HEAP];

  print "$object received _start.  Hi!\n";
                                        # get a new socket
  $heap->{'socket'} = &get_next_client_address();
                                        # start a socket factory
  $heap->{'wheel'} = new POE::Wheel::SocketFactory
    ( SocketDomain  => AF_UNIX,           # in the Unix address family
      RemoteAddress => $unix_server,      # connected to that Unix address
      SuccessState  => 'got_connection',  # sending this message when connected
      FailureState  => 'got_error'        # sending this message upon failure
    );
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and clean up the session.

sub _stop {
  my ($object, $heap) = @_[OBJECT, HEAP];
  print "$object received _stop.\n";
                                        # stop the wheel (closes socket)
  delete $heap->{wheel};
                                        # unlink the unix socket
  if (exists $heap->{'socket'}) {
    if (-e $heap->{'socket'}) {
      unlink($heap->{'socket'})
        or warn "could not unlink $heap->{'socket'}: $!";
    }
    delete $heap->{'socket'};
  }
}

#------------------------------------------------------------------------------
# Proccess an outgoing connection.  This state is invoked when the
# connecting socket makes its connection.  This just spawns off a
# session to send requests and receive responses.

sub got_connection {
  my ($object, $kernel, $socket, $addr, $port) =
    @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];

  print "$object has successfully connected to a server at $addr\n";
                                        # spawn the client session
  new StreamClientSession($socket, $addr, $port);

  # Having a child session causes this session to linger.  To prevent
  # this session from lingering beyond its useful lifetime, it sends
  # itself an explicit _stop message.

  $kernel->yield('_stop');
}

#------------------------------------------------------------------------------
# Process an error.  This also shuts down the client.

sub got_error {
  my ($object, $heap, $operation, $errnum, $errstr) = 
    @_[OBJECT, HEAP, ARG0, ARG1, ARG2];

  print "$object detected $operation error $errnum: $errstr\n";

  # The SocketFactory wheel is the only thing keeping this session
  # alive.  Deleting it causes its destructor to be called.  The
  # session has nothing further to do after the socketfactory is
  # destroyed, so the kernel stops it.

  delete $heap->{'wheel'};
}

###############################################################################
# This package defines a generic INET stream server using the TCP
# protocol.  It can be used with any stream server back-end (see
# StreamServerSession).

package InetTcpServer;

use strict;
use Socket;
use POE::Session;

#------------------------------------------------------------------------------
# Create the InetTcpServer object, and give it to POE to manage as a
# session.

sub new {
  my $type = shift;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self,
                    [ '_start', '_stop', 'got_client', 'got_error' ]
                  );
  undef;
}

#------------------------------------------------------------------------------
# Log that the object has been destroyed.  This will occur after the
# session stops and releases the object's reference.

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event by creating a listening tcp
# socket.

sub _start {
  my ($object, $heap) = @_[OBJECT, HEAP];

  print "$object received _start.  Hi!\n";
                                        # start a socket factory
  $heap->{'wheel'} = new POE::Wheel::SocketFactory
    ( BindAddress    => '127.0.0.1',    # bound to 127.0.0.1, port 30000
      BindPort       => 30000,
      Reuse          => 'yes',          # reusing the address and port
      SuccessState   => 'got_client',   # sending this message when connected
      FailureState   => 'got_error',    # sending this message upon failure
    );

  my ($bind_port, $bind_addr) =
    unpack_sockaddr_in($heap->{wheel}->getsockname());
  print( "********** $object wheel is bound to: ",
         inet_ntoa($bind_addr), " : $bind_port\n"
       );
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and clean up the session.

sub _stop {
  my $object = $_[OBJECT];
  print "$object received _stop.\n";
}

#------------------------------------------------------------------------------
# Process an incoming connection.  This just spawns off a session to
# process requests.

sub got_client {
  my ($object, $socket, $peer_addr, $peer_port) = @_[OBJECT, ARG0, ARG1, ARG2];
  print "$object received a connection.\n";
                                        # spawn the server session
  new StreamServerSession($socket, $peer_addr, $peer_port);
}

#------------------------------------------------------------------------------
# Process an error.  This could shut down the server, but it won't.

sub got_error {
  my ($object, $operation, $errnum, $errstr) = @_[OBJECT, ARG0, ARG1, ARG2];
  print "$object detected $operation error $errnum: $errstr\n";
}

###############################################################################
# This package defines a generic INET stream client using the tcp
# protocol.  It can be used with any stream client back-end (see
# StreamClientSession).

package InetTcpClient;

use strict;
use Socket;
use POE::Session;

#------------------------------------------------------------------------------
# This Perl object method creates a new InetTcpClient object and gives
# it to POE to manage as a session.

sub new {
  my $type = shift;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self,
                    [ '_start', '_stop', 'got_connection', 'got_error' ]
                  );
  undef;
}

#------------------------------------------------------------------------------
# Log that the object has been destroyed.  This will occur after the
# session stops and releases the object's reference.

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and start the tcp client.

sub _start {
  my ($object, $heap) = @_[OBJECT, HEAP];

  print "$object received _start.  Hi!\n";
                                        # start a socket factory
  $heap->{'wheel'} = new POE::Wheel::SocketFactory
    ( RemoteAddress   => '127.0.0.1',      # connected to 127.0.0.1, port 30000
      RemotePort      => 30000,
      Reuse           => 'yes',            # reusing the address and port
      SuccessState    => 'got_connection', # send this message when connected
      FailureState    => 'got_error',      # send this message upon failure
    );
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and clean up the session.

sub _stop {
  my $object = $_[OBJECT];
  print "$object received _stop.\n";
}

#------------------------------------------------------------------------------
# Proccess an outgoing connection.  This state is invoked when the
# connecting socket makes its connection.  This just spawns off a
# session to send requests and receive responses.

sub got_connection {
  my ($object, $kernel, $socket, $addr, $port) =
    @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];

  print( "$object has successfully connected to a server",
         ((defined $addr) ? (' at ' . inet_ntoa($addr)) : ''),
         ((defined $port) ? ":$port" : ''),
         "\n"
       );
                                        # spawn the client session
  new StreamClientSession($socket, $addr, $port);

  # Having a child session causes this session to linger.  To prevent
  # this session from lingering beyond its useful lifetime, it sends
  # itself an explicit _stop message.

  $kernel->yield('_stop');
}

#------------------------------------------------------------------------------
# Process an error.  This also shuts down the client.

sub got_error {
  my ($object, $heap, $operation, $errnum, $errstr) = 
    @_[OBJECT, HEAP, ARG0, ARG1, ARG2];

  print "$object detected $operation error $errnum: $errstr\n";

  # The SocketFactory wheel is the only thing keeping this session
  # alive.  Deleting it causes its destructor to be called.  The
  # session has nothing further to do after the socketfactory is
  # destroyed, so the kernel stops it.

  delete $heap->{'wheel'};
}

###############################################################################

package InetUdpServer;

use strict;
use Socket;
use POE::Session;

sub new {
  my $type = shift;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self,
                    [ '_start', '_stop',
                      'got_socket', 'got_message', 'got_error'
                    ]
                  );
  undef;
}

sub _start {
  my ($object, $heap) = @_[OBJECT, HEAP];

  print "$object received _start.  Hi!\n";

  $heap->{wheel} = new POE::Wheel::SocketFactory
    ( BindAddress    => '127.0.0.1',
      BindPort       => 30001,
      SocketProtocol => 'udp',
      Reuse          => 'yes',
      SuccessState   => 'got_socket',
      FailureState   => 'got_error',
    );

  if (defined $heap->{wheel}) {
    my ($bind_port, $bind_addr) =
      unpack_sockaddr_in($heap->{wheel}->getsockname());
    print( "********** $object wheel is bound to: ",
           inet_ntoa($bind_addr), " : $bind_port\n"
         );
  }
}

sub _stop {
  my $object = $_[OBJECT];
  print "$object received _stop.\n";
}

sub got_socket {
  my ($object, $kernel, $heap, $socket) = @_[OBJECT, KERNEL, HEAP, ARG0];
  print "$object received a socket.\n";

  delete $heap->{wheel};
  $heap->{socket_handle} = $socket;
  $kernel->select_read( $socket, 'got_message' );
}

sub got_message {
  my ($object, $socket) = @_[OBJECT, ARG0];

  my $remote_socket = recv( $socket, my $message = '', 1024, 0 );
  my ($remote_port, $remote_addr) = unpack_sockaddr_in($remote_socket);
  my $human_addr = inet_ntoa($remote_addr);

  print( "$object received a command from $human_addr : $remote_port\n",
         "$object: command=($message)\n",
       );
                                        # rot-13 input
  if ($message =~ /^\s*rot13\s+(.*?)\s*$/i) {
    $message = $1;
    $message =~ tr/a-zA-Z/n-za-mN-ZA-M/;
  }
                                        # display GMT daytime
  elsif ($message =~ /^\s*time\s*$/i) {
    $message = scalar gmtime;
  }

  else {
    $message = 'Unknown command: ' . $message;
  }

  send( $socket, $message, 0, $remote_socket );
}

sub got_error {
  my ($object, $heap, $operation, $errnum, $errstr) =
    @_[OBJECT, HEAP, ARG0, ARG1, ARG2];

  print "$object: $operation error $errnum: $errstr\n";
  delete $heap->{wheel};
  select_read( $heap->{socket_handle} );
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

###############################################################################

package InetUdpClient;

use strict;
use Socket;
use POE::Session;

sub new {
  my $type = shift;
  my $self = bless { }, $type;

  print "$self is being created.\n";

  new POE::Session( $self,
                    [ '_start', '_stop',
                      'got_socket', 'got_message', 'got_error', 'send_message'
                    ]
                  );
  undef;
}

sub _start {
  my ($object, $heap) = @_[OBJECT, HEAP];

  print "$object received _start.  Hi!\n";

  $heap->{wheel} = new POE::Wheel::SocketFactory
    ( RemoteAddress  => '127.0.0.1',
      RemotePort     => 30001,
      SocketProtocol => 'udp',
      SuccessState   => 'got_socket',
      FailureState   => 'got_error',
    );
}

sub _stop {
  my $object = $_[OBJECT];
  print "$object received _stop.\n";
}

sub got_socket {
  my ($object, $kernel, $heap, $socket) = @_[OBJECT, KERNEL, HEAP, ARG0];
  print "$object received a socket.\n";

  delete $heap->{wheel};
  $heap->{socket_handle} = $socket;
  $heap->{server_address} = pack_sockaddr_in(30001, inet_aton('127.0.0.1'));

  $heap->{messages} =
    [ 'rot13 This is a test.',
      'rot13 Guvf vf n grfg.',
      'time'
    ];

  $kernel->select_read($socket, 'got_message');
  $kernel->yield('send_message');
}

sub got_message {
  my ($object, $kernel, $heap, $socket) = @_[OBJECT, KERNEL, HEAP, ARG0];

  my $remote_socket = recv( $heap->{socket_handle},
                            my $message = '', 1024, 0
                          );
  if (defined $remote_socket) {
    my ($remote_port, $remote_addr) = unpack_sockaddr_in($remote_socket);
    my $human_addr = inet_ntoa($remote_addr);

    print( "$object: received response from $human_addr : $remote_port\n",
           "$object: response=($message)\n",
        );
  }

  shift @{$heap->{messages}};
  if (@{$heap->{messages}}) {
    $kernel->yield('send_message');
  }
  else {
    $kernel->select_read($heap->{socket_handle});
    $kernel->delay('send_message');
  }
}

sub send_message {
  my ($object, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];

  print "$object: sending message=($heap->{messages}->[0])\n";

  $kernel->delay('send_message', 5);

  send( $heap->{socket_handle}, $heap->{messages}->[0], 0 )
    or $kernel->yield( 'got_error', 'send', $!+0, $! );
}

sub got_error {
  my ($object, $heap, $operation, $errnum, $errstr) =
    @_[OBJECT, HEAP, ARG0, ARG1, ARG2];

  print "$object: $operation error $errnum: $errstr\n";
  delete $heap->{wheel};
  select_read( $heap->{socket_handle} );
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}


###############################################################################

package ClientPool;

sub new {
  warn "$_[0] is not implemented yet.\n";
}

sub DESTROY {
}

###############################################################################

package Bootstrap;

use strict;
use POE::Session;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;

  my $self = bless { }, $type;

  new POE::Session( $self,
                    [ '_start', '_stop' ]
                  );
  undef;
}

#------------------------------------------------------------------------------

sub _start {
  my $kernel = $_[KERNEL];

  print "Bootstrap session is starting.\n";
                                        # start servers
  new UnixServer();
  new InetTcpServer();
  new InetUdpServer();
                                        # start single clients for testing
  new UnixClient();
  new InetTcpClient();
  new InetUdpClient();
                                        # start client pools
  new ClientPool('UnixClient',    10);
  new ClientPool('InetTcpClient', 10);
  new ClientPool('InetUdpClient', 10);

  # The only thing keeping this session alive is the presence of child
  # sessions, but this session doesn't do anything with them.  Sending
  # an explicit _stop causes this session to be removed and the
  # children to be given to its parents.

  $kernel->yield('_stop');
}

#------------------------------------------------------------------------------

sub _stop {
  my $object = $_[OBJECT];
  print "$object has stopped.\n";
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  print "$self is destroyed.\n";
}

###############################################################################
# Create the bootstrap session, and run the kernel until everything is
# done.

package main;

new Bootstrap();
$poe_kernel->run();

exit;
