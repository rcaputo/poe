#!perl -w -I..
# $Id$

# This program tests POE::Wheel::SocketFactory.  Basically, it is
# thrash.perl, but for AF_UNIX, AF_INET tcp, and AF_INET udp sockets.

use strict;

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
use POE;

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
use POE;

#------------------------------------------------------------------------------
# Create a Perl object, and give it to POE to manage as a session.

sub new {
  my ($type, $socket) = @_;
  my $self = bless { }, $type;

  print "$self is being created.\n";
                                        # wrap this object in a POE session
  new POE::Session( $self, [ '_start', '_stop', 'got_response', 'got_error' ],
                                        # ARG0
                    [ $socket ]
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
    ( Handle => $socket,                # on this socket handle
      Driver => new POE::Driver::SysRW, # using sysread and syswrite
      Filter => new POE::Filter::Line,  # and parsing streams as lines
      InputState => 'got_response',     # generate this event upon input
      ErrorState => 'got_error'         # and this event in an error occurs
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
use POE;

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
      SocketType   => SOCK_STREAM,      # create stream sockets
      BindAddress  => $unix_server,     # bound to this Unix address
      ListenQueue  => 5,                # listen, with a 5-connection queue
      SuccessState => 'got_client',     # sending this message when connected
      FailureState => 'got_error',      # sending this message upon failure
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
use POE;

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
                                        # start a socket factory
  $heap->{'wheel'} = new POE::Wheel::SocketFactory
    ( SocketDomain => AF_UNIX,          # in the Unix address family
      SocketType => SOCK_STREAM,        # create stream sockets
      BindAddress => &get_next_client_address(), # bound to this Unix address
      RemoteAddress => $unix_server,    # connected to that Unix address
      SuccessState => 'got_connection', # sending this message when connected
      FailureState => 'got_error'       # sending this message upon failure
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
  my ($object, $kernel, $socket) = @_[OBJECT, KERNEL, ARG0];

  print "$object has successfully connected to a server.\n";
                                        # spawn the client session
  new StreamClientSession($socket);

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
use POE;

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
    ( SocketDomain   => AF_INET,        # in the AF_INET address family
      SocketType     => SOCK_STREAM,    # create stream sockets
      SocketProtocol => 'tcp',          # using the tcp protocol
      BindAddress    => '127.0.0.1',    # bound to 127.0.0.1, port 30000
      BindPort       => 30000,
      ListenQueue    => 5,              # listen, with a 5-connection queue
      Reuse          => 'yes',          # reusing the address and port
      SuccessState   => 'got_client',   # sending this message when connected
      FailureState   => 'got_error',    # sending this message upon failure
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
use POE;

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
    ( SocketDomain => AF_INET,          # in the Internet address family
      SocketType => SOCK_STREAM,        # create stream sockets
      SocketProtocol => 'tcp',          # using the tcp protocol
      RemoteAddress => '127.0.0.1',     # connected to 127.0.0.1, port 30000
      RemotePort => 30000,
      Reuse          => 'yes',          # reusing the address and port
      SuccessState => 'got_connection', # sending this message when connected
      FailureState => 'got_error',      # sending this message upon failure
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
  my ($object, $kernel, $socket) = @_[OBJECT, KERNEL, ARG0];

  print "$object has successfully connected to a server.\n";
                                        # spawn the client session
  new StreamClientSession($socket);

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

sub new {
  warn "$_[0] is not implemented yet.\n";
}

sub DESTROY {
}

###############################################################################

package InetUdpClient;

sub new {
  warn "$_[0] is not implemented yet.\n";
}

sub DESTROY {
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
use POE;

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
