#!perl -w -I..
# $Id$

# Tests the SocketFactory wheel, in AF_UNIX, AF_INET/tcp and AF_INET/udp
# capacities.

use strict;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);

my $kernel = new POE::Kernel();

#------------------------------------------------------------------------------

my $unix_server = '/tmp/poe-usrv';
my $unix_client = '/tmp/poe-';
my $unix_client_count = '0000';

###############################################################################

package StreamServerSession;

use strict;

sub new {
  my ($type, $kernel, $socket, $peer_addr, $peer_port) = @_;
  my $self = bless { 'socket' => $socket,
                     'peer addr' => $peer_addr,
                     'peer port' => $peer_port,
                   }, $type;

  new POE::Session( $kernel,
                    $self,
                    [ '_start', '_stop', 'got_line', 'got_error', 'flushed' ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

sub _start {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _start.  hi!\n";

  $me->{'wheel'} = new POE::Wheel::ReadWrite
    ( $k,
      'Handle' => delete $o->{'socket'},
      'Driver' => new POE::Driver::SysRW(),
      'Filter' => new POE::Filter::Line(),
      'InputState' => 'got_line',
      'ErrorState' => 'got_error',
      'FlushedState' => 'flushed'
    );

  $me->{'protocol state'} = 'running';
  $me->{'wheel'}->put
    ( "Greetings" .
      ((defined $o->{'peer_addr'}) ? (" $o->{'peer_addr'}") : '') .
      ((defined $o->{'peer_port'}) ? (" ($o->{'peer_port'})") : '')
    );
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _stop.  bye!\n";
  delete $me->{'wheel'};
}

sub got_line {
  my ($o, $k, $me, $from, $line) = @_;

  print ref($o), " got a command: $line\n";

  if ($me->{'protocol state'} eq 'quitting') {
    return;
  }

  if ($line =~ /^\s*rot13\s+(.*?)\s*$/i) {
    $line = $1;
    $line =~ tr/a-zA-Z/n-za-mN-ZA-M/;
    $me->{'wheel'}->put($line);
    return;
  }

  if ($line =~ /^\s*time\s*$/i) {
    $me->{'wheel'}->put(scalar gmtime);
    return;
  }

  if ($line =~ /^\s*quit\s*/i) {
    $me->{'protocol state'} = 'quitting';
    $me->{'wheel'}->put("Bye!");
    return;
  }
}

sub got_error {
  my ($o, $k, $me, $from, $op, $errnum, $errstr) = @_;
  print ref($o), " got an error during $op: ($errnum) $errstr\n";
  delete $me->{'wheel'};
}

sub flushed {
  my ($o, $k, $me, $from) = @_;
  if ($me->{'protocol state'} eq 'quitting') {
    delete $me->{'wheel'};
  }
}

###############################################################################

package StreamClientSession;

use strict;

sub new {
  my ($type, $kernel, $socket) = @_;
  my $self = bless { 'socket' => $socket }, $type;

  new POE::Session( $kernel,
                    $self, [ '_start', '_stop', 'got_response', 'got_error' ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

sub _start {
  my ($o, $k, $me, $from) = @_;

  $me->{'wheel'} = new POE::Wheel::ReadWrite
    ( $k,
      Handle => delete $o->{'socket'},
      Driver => new POE::Driver::SysRW,
      Filter => new POE::Filter::Line,
      InputState => 'got_response',
      ErrorState => 'got_error'
    );

  $me->{'commands'} =
    [ 'rot13 This is a test.', 
      'rot13 Guvf vf n grfg.',
      'time',
      'quit'
    ];
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _stop.  bye!\n";
  delete $me->{'wheel'};
}

sub got_response {
  my ($o, $k, $me, $from, $line) = @_;
  print ref($o), " got a response: $line\n";

  if (@{$me->{'commands'}}) {
    $me->{'wheel'}->put(shift @{$me->{'commands'}});
  }
}

sub got_error {
  my ($o, $k, $me, $from, $op, $errnum, $errstr) = @_;
  if ($errnum == 0) {
    print ref($o), " got $op error $errnum: $errstr\n";
  }
  else {
    print ref($o), " detected a remote disconnect.\n";
    delete $me->{'wheel'};
  }
}

###############################################################################

package UnixServer;

use strict;
use Socket;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session( $kernel,
                    $self,
                    [ '_start', '_stop', 'got_client', 'got_error' ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

sub _start {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _start.  hi!\n";

  unlink $unix_server;

  $me->{'wheel'} = new POE::Wheel::SocketFactory
    ( $k,
      SocketDomain => AF_UNIX,
      SocketType   => SOCK_STREAM,
      BindAddress  => $unix_server,
      ListenQueue  => 5,
      SuccessState => 'got_client',
      FailureState => 'got_error',
    );
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _stop.  bye!\n";
  delete $me->{'wheel'};
}

sub got_client {
  my ($o, $k, $me, $from, $socket, $peer_addr, $peer_port) = @_;
  print ref($o), " got a connection, socket $socket\n";
  new StreamServerSession($k, $socket, $peer_addr, $peer_port);
}

sub got_error {
  my ($o, $k, $me, $from, $op, $errnum, $errstr) = @_;
  print ref($o), " got $op error $errnum: $errstr\n";
}

###############################################################################

package UnixClient;

use strict;
use Socket;

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

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session( $kernel,
                    $self, [ '_start', '_stop', 'got_connection', 'got_error' ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

sub _start {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _start.  hi!\n";

  $me->{'wheel'} = new POE::Wheel::SocketFactory
    ( $k,
      SocketDomain => AF_UNIX,
      SocketType => SOCK_STREAM,
      BindAddress => &get_next_client_address(),
      RemoteAddress => $unix_server,
      SuccessState => 'got_connection',
      FailureState => 'got_error'
    );
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _stop.  bye!\n";
  delete $me->{'wheel'};
}

sub got_connection {
  my ($o, $k, $me, $from, $socket) = @_;
  print ref($o), " got a connection, socket $socket\n";
  new StreamClientSession($k, $socket);
  $k->yield('_stop');
}

sub got_error {
  my ($o, $k, $me, $from, $op, $errnum, $errstr) = @_;
  print ref($o), " got $op error $errnum: $errstr\n";
}

###############################################################################

package InetTcpServer;

use strict;
use Socket;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session( $kernel,
                    $self,
                    [ '_start', '_stop', 'got_client', 'got_error' ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

sub _start {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _start.  hi!\n";

  $me->{'wheel'} = new POE::Wheel::SocketFactory
    ( $k,
      SocketDomain   => AF_INET,
      SocketType     => SOCK_STREAM,
      SocketProtocol => 'tcp',
      BindAddress    => '127.0.0.1',
      BindPort       => 30000,
      ListenQueue    => 5,
      SuccessState   => 'got_client',
      FailureState   => 'got_error',
    );
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _stop.  bye!\n";
  delete $me->{'wheel'};
}

sub got_client {
  my ($o, $k, $me, $from, $socket, $peer_addr, $peer_port) = @_;
  print ref($o), " got a connection, socket $socket\n";
  new StreamServerSession($k, $socket, $peer_addr, $peer_port);
}

sub got_error {
  my ($o, $k, $me, $from, $op, $errnum, $errstr) = @_;
  print ref($o), " got $op error $errnum: $errstr\n";
}

###############################################################################

package InetTcpClient;

use strict;
use Socket;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session( $kernel,
                    $self, [ '_start', '_stop', 'got_connection', 'got_error' ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

sub _start {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _start.  hi!\n";

  $me->{'wheel'} = new POE::Wheel::SocketFactory
    ( $k,
      SocketDomain => AF_INET,
      SocketType => SOCK_STREAM,
      SocketProtocol => 'tcp',
      RemoteAddress => '127.0.0.1',
      RemotePort => 30000,
      SuccessState => 'got_connection',
      FailureState => 'got_error',
    );
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  print ref($o), " got _stop.  bye!\n";
  delete $me->{'wheel'};
}

sub got_connection {
  my ($o, $k, $me, $from, $socket) = @_;
  print ref($o), " got a connection, socket $socket\n";
  new StreamClientSession($k, $socket);
  $k->yield('_stop');
}

sub got_error {
  my ($o, $k, $me, $from, $op, $errnum, $errstr) = @_;
  print ref($o), " got $op error $errnum: $errstr\n";
}
      
###############################################################################

package InetUdpServer;

sub new {
  my ($type, $kernel) = @_;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

###############################################################################

package InetUdpClient;

sub new {
  my ($type, $kernel) = @_;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

###############################################################################

package ClientPool;

sub new {
  my ($type, $kernel, $client_type, $pool_size) = @_;
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

###############################################################################

package Bootstrap;

sub new {
  my ($type, $kernel) = @_;

  my $self = bless { }, $type;

  new POE::Session( $kernel,
                    $self,
                    [ '_start' ]
                  );
  undef;
}

sub _start {
  my ($o, $k, $me, $from) = @_;
                                        # start servers
  new UnixServer($kernel);
  new InetTcpServer($kernel);
  new InetUdpServer($kernel);
                                        # start single clients for testing
  new UnixClient($kernel);
  new InetTcpClient($kernel);
  new InetUdpClient($kernel);
                                        # start client pools
  new ClientPool($kernel, 'UnixClient',    10);
  new ClientPool($kernel, 'InetTcpClient', 10);
  new ClientPool($kernel, 'InetUdpClient', 10);
                                        # force me to die
  $k->yield('_stop');
}

sub DESTROY {
  my $self = shift;
  print "$self is destroyed\n";
}

###############################################################################

package main;

new Bootstrap($kernel);
$kernel->run();

exit;
