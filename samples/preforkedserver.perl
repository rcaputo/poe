#!/usr/bin/perl -w
# $Id$

# This is a proof of concept for pre-forking POE servers.  It
# maintains pool of five servers (one master; four slave).  At some
# point, it would be nice to make the server pool management a
# reusable wheel.

use strict;
use lib '..';
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);

###############################################################################
# This is a pre-forked server's session object.  It is given a handle
# from the server and processes transactions on it.

package PreforkedSession;

use strict;
use POE::Session;

sub DEBUG { 1 }

#------------------------------------------------------------------------------
# Create the preforked server session, and give it to POE to manage.

sub new {
  my ($type, $socket, $peer_addr, $peer_host) = @_;
  my $self = bless { }, $type;

  POE::Session->new( $self,
                     [ qw( _start _stop command error flushed ) ],
                     # ARG0, ARG1, ARG2
                     [ $socket, $peer_addr, $peer_host ]
                   );
  undef;
}

#------------------------------------------------------------------------------
# This state accepts POE's standard _start event and starts processing
# I/O on the client socket

sub _start {
  my ($heap, $socket, $peer_addr, $peer_port) = @_[HEAP, ARG0, ARG1, ARG2];
                                        # remember information for the logs
  $heap->{addr} = $peer_addr;
  $heap->{port} = $peer_port;
                                        # become a reader/writer
  $heap->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $socket,                 # on this socket
      Driver       => POE::Driver::SysRW->new, # using sysread and syswrite
      Filter       => POE::Filter::Line->new,  # parsing I/O as lines
      InputState   => 'command',               # generating this event on input
      ErrorState   => 'error',                 # generating this event on error
      FlushedState => 'flushed'                # generating this event on flush
    );

  DEBUG &&
    print "$$: handling connection from $heap->{addr} : $heap->{port}\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and log the close.

sub _stop {
  my $heap = $_[HEAP];
  DEBUG && print "$$: session $heap->{addr} : $heap->{port} has stopped\n";
}

#------------------------------------------------------------------------------
# This state is invoked by the ReadWrite wheel for each complete
# request it receives.

sub command {
  my ($heap, $input) = @_[HEAP, ARG0];
                                        # just echo the input back
  $heap->{wheel}->put("Echo: $input");
}

#------------------------------------------------------------------------------
# This state is invoked when the ReadWrite wheel encounters an I/O
# error.  It logs the error, and shuts down the session.

sub error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  if ($errnum) {
    warn( "$$: connection with $heap->{addr} : $heap->{port} encountered " .
          "$operation error $errnum: $errstr\n"
        );
  }
                                        # stop the session
  delete $heap->{wheel};
}

#------------------------------------------------------------------------------
# This state is invoked when the session's response has been flushed
# to the socket.  Since the "protocol" specifies one transaction per
# socket, it shuts down the ReadWrite wheel, ending the session.

sub flushed {
  my $heap = $_[HEAP];
  DEBUG && print "$$: response sent to $heap->{addr} : $heap->{port}\n";
  delete $heap->{wheel};
}

###############################################################################
# This is a pre-forked server object.  It creates a listening socket,
# then forks off many child processes to handle connections.  This
# differs from the PCB pre-forking server example in that the parent
# process continues to accept requests.

package PreforkedServer;

use strict;
use Socket;
use POSIX qw(ECHILD EAGAIN);
use POE::Session;

sub DEBUG { 1 }

#------------------------------------------------------------------------------
# Create the preforked server, and give it to POE to manage.

sub new {
  my ($type, $processes) = @_;
  my $self = bless { }, $type;

  POE::Session->new( $self,
                     [ qw(_start _stop fork retry signal connection) ],
                     # ARG0
                     [ $processes ]
                   );
  undef;
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and start the server processes.

sub _start {
  my ($kernel, $heap, $processes) = @_[KERNEL, HEAP, ARG0];
                                        # create a socket factory
  $heap->{wheel} = POE::Wheel::SocketFactory->new
    ( BindPort       => 8888,           # bind on this port
      SuccessState   => 'connection',   # generate this event for connections
      FailureState   => 'error'         # generate this event for errors
    );
                                        # watch for signals
  $kernel->sig('CHLD', 'signal');
  $kernel->sig('INT', 'signal');
                                        # keep track of children
  $heap->{children} = {};
  $heap->{'failed forks'} = 0;
                                        # change behavior for children
  $heap->{'is a child'} = 0;
                                        # fork the initial set of children
  foreach (2..$processes) {
                                        # yield() posts events to this session
    $kernel->yield('fork');
  }

  DEBUG && print "$$: master server has started\n";
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and stop all the children, too.
# The 'children' hash is maintained in the 'fork' and 'signal'
# handlers.  It's empty for children.

sub _stop {
  my $heap = $_[HEAP];
                                        # kill the child servers
  foreach (keys %{$heap->{children}}) {
    DEBUG && print "$$: server is killing child $_ ...\n";
    kill -1, $_;
  }
  DEBUG && print "$$: server is stopped\n";
}

#------------------------------------------------------------------------------
# The server has been requested to fork, so fork already.

sub fork {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # children should not honor this event
  return if ($heap->{'is a child'});
                                        # try to fork
  my $pid = fork();
                                        # did the fork fail?
  unless (defined($pid)) {
                                        # try again later, if a temporary error
    if (($! == EAGAIN) || ($! == ECHILD)) {
      $heap->{'failed forks'}++;
      $kernel->delay('retry', 1);
    }
                                        # fail permanently, if fatal
    else {
      warn "Can't fork: $!\n";
      $kernel->yield('_stop');
    }
    return;
  }
                                        # successful fork; parent keeps track
  if ($pid) {
    $heap->{children}->{$pid} = 1;
    DEBUG &&
      print( "$$: master server forked a new child.  children: (",
             join(' ', keys %{$heap->{children}}), ")\n"
           );
  }
                                        # child becomes a child server
  else {
    $heap->{'is a child'}   = 1;        # don't allow fork
    $heap->{children}       = { };      # don't kill child processes
    $heap->{connections}    = 0;        # limit sessions, then die off

    DEBUG && print "$$: child server has been forked\n";
  }
}

#------------------------------------------------------------------------------
# Retry failed forks.  This is invoked (after a brief delay) if the
# 'fork' state encountered a temporary error.

sub retry {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Multiplex the delayed 'retry' event into enough 'fork' events to
  # make up for the temporary fork errors.

  for (1 .. $heap->{'failed forks'}) {
    $kernel->yield('fork');
  }
                                        # reset the failed forks counter
  $heap->{'failed forks'} = 0;
}

#------------------------------------------------------------------------------
# Process signals.  SIGCHLD causes this session to fork off a
# replacement for the lost child.  Terminal signals aren't handled, so
# the session will stop on SIGINT.  The _stop event handler takes care
# of cleanup.

sub signal {
  my ($kernel, $heap, $signal, $pid, $status) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

  # Some operating systems call this SIGCLD.  POE's kernel translates
  # CLD to CHLD, so developers only need to check for the one version.

  if ($signal eq 'CHLD') {
                                        # if it was one of ours; fork another
    if (delete $heap->{children}->{$pid}) {
      DEBUG &&
        print( "$$: master caught SIGCHLD.  children: (",
               join(' ', keys %{$heap->{children}}), ")\n"
             );
      $kernel->yield('fork');
    }
  }
                                        # don't handle terminal signals
  return 0;
}

#------------------------------------------------------------------------------
# This state is invoked when the SocketFactory wheel hears a
# connection.  It creates a new session to handle the connection.

sub connection {
  my ($kernel, $heap, $socket, $peer_addr, $peer_port) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

  $peer_addr = inet_ntoa($peer_addr);
  DEBUG &&
    print "$$: server received a connection from $peer_addr : $peer_port\n";

  PreforkedSession->new($socket, $peer_addr, $peer_port);

  # Stop child sessions after a certain number of connections have
  # been handled.  This enables the program to test SIGCHLD handling
  # and re-forking.

  if ($heap->{'is a child'}) {
    if (++$heap->{connections} >= 1) {
      delete $heap->{wheel};
      $kernel->yield('_stop');
    }
  }
}

###############################################################################
# Start a pre-forked server, with a pool of 5 processes, and run them
# until it's time to exit.

package main;

PreforkedServer->new(5);

print "*** If all goes well, there should be an echo server on port 8888.\n";

$poe_kernel->run();

exit;
