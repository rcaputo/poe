#!perl -w -I..
# $Id$

# This program creates a server session and an infinitude of clients
# in order to exercise POE for potential long-term problems.

# This program is also something of a benchmark.  Every ten seconds it
# displays the average number of connections per second.

use strict;

use POE qw(Wheel::ListenAccept Wheel::ReadWrite Driver::SysRW Filter::Line
           Wheel::SocketFactory
          );

sub DEBUG () { 0 }

my $server_port = 12345;

#------------------------------------------------------------------------------

package Client;

use strict;
use Socket;
sub DEBUG () { 0 }

sub new {
  my ($type, $kernel, $serial) = @_;
  my $self = bless { 'serial' => $serial }, $type;

  new POE::Session( $kernel,
                    $self, [ qw(_start _stop receive error connected signals) ]
                  );

  DEBUG && print "\t\t\tclient $self->{'serial'} created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
  DEBUG && print "\t\t\tclient $self->{'serial'} destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $kernel->sig('INT', 'signals');

  $namespace->{'wheel'} = new POE::Wheel::SocketFactory
    ( $kernel,
      SocketDomain   => AF_INET,
      SocketType     => SOCK_STREAM,
      SocketProtocol => 'tcp',
      RemoteAddress  => '127.0.0.1',
      RemotePort     => $server_port,
      SuccessState   => 'connected',
      FailureState   => 'error',
    );
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
  DEBUG && print "\t\t\tclient $self->{'serial'} stopped\n";
  delete $namespace->{'wheel'};
}

sub connected {
  my ($self, $kernel, $namespace, $from, $socket) = @_;

  DEBUG && print "\t\t\tclient $self->{'serial'} connected\n";

  $namespace->{'wheel'} = new POE::Wheel::ReadWrite
    ( $kernel,
      'Handle' => $socket,
      'Driver' => new POE::Driver::SysRW(),
      'Filter' => new POE::Filter::Line(),
      'InputState' => 'receive',
      'ErrorState' => 'error',
    );
}

sub receive {
  my ($self, $kernel, $namespace, $from, $line) = @_;
  DEBUG && print "\t\t\tclient $self->{'serial'} received $line\n";
}

sub error {
  my ($self, $k, $namespace, $from, $op, $errnum, $errstr) = @_;
  DEBUG && print "\t\t\tclient $self->{'serial'} $op error $errnum: $errstr\n";
  delete $namespace->{'wheel'};
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
  DEBUG && print "\t\t\t***** $namespace caught SIG$signal_name\n";
  return (1) if ($signal_name eq 'INT');
}

#------------------------------------------------------------------------------
# manage a pool of clients

package ClientPool;

use strict;
sub DEBUG () { 0 }

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session($kernel, $self, [ qw(_start _stop _child signals initialize)
                                   ]
                  );

  DEBUG && print "\t\t$self created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
  DEBUG && print "\t\t$self destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $self->{'status'} = 'running';
  $kernel->sig('INT', 'signals');

  $self->{'children'} = 0;
  $self->{'client serial'} = 0;

  $self->{'bench start'} = time();
  $self->{'bench count'} = 0;

  $kernel->post($namespace, 'initialize');

  DEBUG && print "\t\t$self started\n";
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
  $kernel->signal('server', 'QUIT');
  DEBUG && print "\t\t$self stopped\n";
}

# This kludge works around the fact that "new IO::Socket::INET" blocks
# by default.  If it was a plain loop, then the Kernel couldn't dispatch
# select events to the server, and this would block (until the connection
# sockets timed out).
#
# Fortunately, this sort of badness only is a problem when the server and
# client share the same event queue.

sub initialize {
  my ($self, $kernel, $namespace) = @_;

  if (($self->{'status'} eq 'running') && ($self->{'children'} < 25)) {
    $self->{'children'}++;
    new Client($kernel, ++$self->{'client serial'});
    $kernel->post($namespace, 'initialize');
  }
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
  $self->{'status'} = 'shutting down';
  DEBUG && print "\t\t***** $namespace caught SIG$signal_name\n";
  return ($signal_name ne 'INT');
}

sub _child {
  my ($self, $kernel, $namespace) = @_;

  $self->{'children'}--;

  DEBUG && print "\t\tSERVER POOL CHILDREN: $self->{'children'}\n";

  if ($self->{'status'} eq 'running') {
    $self->{'children'}++;
    new Client($kernel, ++$self->{'client serial'});
  }

  $self->{'bench count'}++;

  my $elapsed = time() - $self->{'bench start'};
  if ($elapsed >= 10) {
    print "bench: ", $self->{'bench count'}, ' / ', $elapsed, ' = ',
          $self->{'bench count'} / $elapsed, "\n";
    $self->{'bench count'} = 0;
    $self->{'bench start'} = time();
    exit if (time() - $^T >= 60.0);
  }
}

#------------------------------------------------------------------------------
# handle a connection on the server side

package ServerSession;

use strict;
use Socket;
sub DEBUG () { 0 }

sub new {
  my ($type, $kernel, $handle, $peer_host, $peer_port) = @_;

  my $self = bless { 'handle' => $handle,
                     'peer host' => $peer_host,
                     'peer port' => $peer_port,
                   }, $type;

  new POE::Session($kernel, $self, [ qw(_start _stop receive flushed error
                                        signals)
                                   ]
                  );

  DEBUG && print "\t$self created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
  DEBUG && print "\t$self destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $kernel->sig('INT', 'signals');

  $namespace->{'wheel'} = new POE::Wheel::ReadWrite
    ( $kernel,
      'Handle' => delete $self->{'handle'},
      'Driver' => new POE::Driver::SysRW(),
      'Filter' => new POE::Filter::Line(),
      'InputState'   => 'receive',
      'ErrorState'   => 'error',
      'FlushedState' => 'flushed',
    );

  $namespace->{'wheel'}->put
    ( "hi, " . inet_ntoa($self->{'peer host'}) .
      ":$self->{'peer port'}, at " . time()
    );

  DEBUG && print "\t$namespace: started\n";
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
  DEBUG && print "\t$self stopped\n";
}

sub receive {
  my ($self, $kernel, $namespace, $from, $line) = @_;
  DEBUG && print "\t$namespace: received $line\n";
}

sub error {
  my ($self, $k, $namespace, $from, $op, $errnum, $errstr) = @_;
  DEBUG && print "\t$namespace: $op error $errnum: $errstr\n";
  delete $namespace->{'wheel'};
}

sub flushed {
  my ($self, $kernel, $namespace, $from) = @_;
  DEBUG && print "\t$namespace: flushed\n";
  delete $namespace->{'wheel'};
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
  DEBUG && print "\t***** $namespace caught SIG$signal_name\n";
  return ($signal_name eq 'INT');
}

#------------------------------------------------------------------------------
# a simple daytime server

package Server;

use strict;
use Socket;
sub DEBUG () { 0 }

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session($kernel, $self, [ qw(_start accept accept_error signals) ]
                  );

  DEBUG && print "$self created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
  DEBUG && print "$self destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $kernel->alias_set('server');
  $kernel->sig('INT', 'signals');

  $namespace->{'wheel'} = new POE::Wheel::SocketFactory
    ( $kernel,
      Reuse          => 'yes',
      SocketDomain   => AF_INET,
      SocketType     => SOCK_STREAM,
      SocketProtocol => 'tcp',
      BindAddress    => '127.0.0.1',
      BindPort       => $server_port,
      ListenQueue    => 5,
      SuccessState   => 'accept',
      FailureState   => 'accept_error',
    );
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
  DEBUG && print "$self stopped\n";
}

sub accept_error {
  my ($self, $kernel, $namespace, $from, $op, $errnum, $errstr) = @_;
  print "$op error $errnum: $errstr\n";
}

sub accept {
  my ($self, $kernel, $namespace, $from, $accepted_handle, $host, $port) = @_;
  new ServerSession($kernel, $accepted_handle, $host, $port);
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
  DEBUG && print "***** $namespace caught SIG$signal_name\n";
  return ($signal_name eq 'INT');
}

#------------------------------------------------------------------------------

package main;

my $kernel = new POE::Kernel();

new Server($kernel);
new ClientPool($kernel);

$kernel->run();

exit;
