#!perl -w -I..
# $Id$

# It is said that IO::* leaks memory.  This program creates a server
# session and an infinitude of clients in order to exercise POE (and
# IO) for potential long-term problems.

# This program is also something of a benchmark.  Every ten seconds
# it displays the average connections per second.

use strict;

use POE qw(Wheel::ListenAccept Wheel::ReadWrite Driver::SysRW Filter::Line);
use IO::Socket::INET;

my $server_port = 12345;

#------------------------------------------------------------------------------

package Client;

sub new {
  my ($type, $kernel, $serial) = @_;
  my $self = bless { 'serial' => $serial }, $type;

  new POE::Session($kernel, $self, [ qw(_start _stop receive error signals) ]);

#  print "\t\t\tclient $self->{'serial'} created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
#  print "\t\t\tclient $self->{'serial'} destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $kernel->sig('INT', 'signals');

  my $connector = new IO::Socket::INET
    ( 'PeerAddr' => "127.0.0.1:$server_port",
      'Reuse'    => 'yes',
      'Proto'    => 'tcp',
    );

  if ($connector) {
    $namespace->{'wheel'} = new POE::Wheel::ReadWrite
      ( $kernel,
        'Handle' => $connector,
        'Driver' => new POE::Driver::SysRW(),
        'Filter' => new POE::Filter::Line(),
        'InputState' => 'receive',
        'ErrorState' => 'error',
      );
#    print "\t\t\tclient $self->{'serial'} started\n";
  }
  else {
    warn "\t\t\tclient $self->{'serial'} could not connect: $!\n";
  }
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
#  print "\t\t\tclient $self->{'serial'} stopped\n";
}

sub receive {
  my ($self, $kernel, $namespace, $from, $line) = @_;
#  print "\t\t\tclient $self->{'serial'} received $line\n";
}

sub error {
  my ($self, $k, $namespace, $from, $op, $errnum, $errstr) = @_;
#  print "\t\t\tclient $self->{'serial'} $op error $errnum: $errstr\n";
  delete $namespace->{'wheel'};
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
#  print "\t\t\t***** $namespace caught SIG$signal_name\n";
  return (1) if ($signal_name eq 'INT');
}

#------------------------------------------------------------------------------
# manage a pool of clients

package ClientPool;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session($kernel, $self, [ qw(_start _stop _child signals initialize)
                                   ]
                  );

#  print "\t\t$self created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
#  print "\t\t$self destroyed\n";
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

#  print "\t\t$self started\n";
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
  $kernel->signal('server', 'QUIT');
#  print "\t\t$self stopped\n";
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
#  print "\t\t***** $namespace caught SIG$signal_name\n";
  return ($signal_name ne 'INT');
}

sub _child {
  my ($self, $kernel, $namespace) = @_;

  $self->{'children'}--;

#  print "\t\tSERVER POOL CHILDREN: $self->{'children'}\n";

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
  }
}

#------------------------------------------------------------------------------
# handle a connection on the server side

package ServerSession;

sub new {
  my ($type, $kernel, $handle) = @_;
  my $self = bless { 'handle' => $handle }, $type;

  $self->{'peer host'} = $handle->peerhost();
  $self->{'peer port'} = $handle->peerport();

  new POE::Session($kernel, $self, [ qw(_start _stop receive flushed error
                                        signals)
                                   ]
                  );

#  print "\t$self created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
#  print "\t$self destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $kernel->sig('INT', 'signals');

  $namespace->{'wheel'} = new POE::Wheel::ReadWrite
    ( $kernel,
      'Handle' => delete $self->{'handle'},
      'Driver' => new POE::Driver::SysRW(),
      'Filter' => new POE::Filter::Line(),
      'InputState' => 'receive',
      'ErrorState' => 'error',
      'FlushedState' => 'flushed',
    );

  $namespace->{'wheel'}->put
    ( "hi, $self->{'peer host'}:$self->{'peer port'}, at " . time()
    );

#  print "\t$namespace: started\n";
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
#  print "\t$self stopped\n";
}

sub receive {
  my ($self, $kernel, $namespace, $from, $line) = @_;
#  print "\t$namespace: received $line\n";
}

sub error {
  my ($self, $k, $namespace, $from, $op, $errnum, $errstr) = @_;
#  print "\t$namespace: $op error $errnum: $errstr\n";
  delete $namespace->{'wheel'};
}

sub flushed {
  my ($self, $kernel, $namespace, $from) = @_;
#  print "\t$namespace: flushed\n";
  delete $namespace->{'wheel'};
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
#  print "\t***** $namespace caught SIG$signal_name\n";
  return ($signal_name eq 'INT');
}

#------------------------------------------------------------------------------
# a simple daytime server

package Server;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;

  new POE::Session($kernel, $self, [ qw(_start accept accept_error signals) ]
                  );

#  print "$self created\n";

  undef;
}

sub DESTROY {
  my $self = shift;
#  print "$self destroyed\n";
}

sub _start {
  my ($self, $kernel, $namespace) = @_;

  $kernel->alias_set('server');
  $kernel->sig('INT', 'signals');

  my $listener = new IO::Socket::INET
    ( 'LocalPort' => $server_port,
      'Listen'    => 5,
      'Proto'     => 'tcp',
      'Reuse'     => 'yes',
    );

  if ($listener) {
    $namespace->{'wheel'} = new POE::Wheel::ListenAccept
      ( $kernel,
        'Handle'      => $listener,
        'AcceptState' => 'accept',
        'ErrorState'  => 'accept_error',
      );
                                        # start client pool, only if server ok
    new ClientPool($kernel);
  }
  else {
    warn "could not start thrash server: $!\n";
  }
}

sub _stop {
  my ($self, $kernel, $namespace) = @_;
#  print "$self stopped\n";
}

sub accept_error {
  my ($self, $kernel, $namespace, $from, $op, $errnum, $errstr) = @_;
#  print "$op error $errnum: $errstr\n";
}

sub accept {
  my ($self, $kernel, $namespace, $from, $accepted_handle) = @_;
  new ServerSession($kernel, $accepted_handle);
}

sub signals {
  my ($self, $kernel, $namespace, $from, $signal_name) = @_;
#  print "***** $namespace caught SIG$signal_name\n";
  return ($signal_name eq 'INT');
}

#------------------------------------------------------------------------------

package main;

my $kernel = new POE::Kernel();

new Server($kernel);

$kernel->run();

exit;
