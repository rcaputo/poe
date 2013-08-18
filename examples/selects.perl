#!/usr/bin/perl -w

# This is an early, basic test of POE's filehandle selecting
# mechanism.  It was written before POE::Wheel classes were conceived.
# In fact, Wheels were invented after realizing that this program's
# 'accept', 'read' and 'write' states would probably need to be
# replicated for every TCP server that came after this one.

# Anyway, this program creates two sessions.  The first is an average
# TCP chargen server, and the second is an average line-based client.
# The client connects to the server, displays a few lines of chargen
# output, and closes.  The server remains active, and it can be
# connected to by other clients, such as netcat or telnet.

# This is a pre-wheel sockets test.  It's one of the few that uses
# IO::Socket.  All the others (with exception of wheels.perl) have
# been adapted to use POE::Wheel::SocketFactory.

# If some aspects of using sessions are confusing, please see the
# *session*.perl tests.  They are commented in more detail.

use strict;
use lib '../lib';

use POE;
use IO::Socket;
use POSIX qw(EAGAIN);
                                        # the chargen server's listen port
my $chargen_port = 32100;

#==============================================================================
# This is the session that will handle a client connection to the
# server.  An instance of it is spawned off from the server each time
# a connection comes in.

#------------------------------------------------------------------------------
# Start the chargen connection.

sub connection_start {
  my ($kernel, $heap, $socket_handle, $peer_host, $peer_port) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
                                        # hello, world!
  print "Starting chargen connection with $peer_host:$peer_port ...\n";
                                        # watch for SIGINT and SIGPIPE
  $kernel->sig('INT', 'signal');
  $kernel->sig('PIPE', 'signal');
                                        # remember things for later
  $heap->{'host'} = $peer_host;
  $heap->{'port'} = $peer_port;
  $heap->{'char'} = 32;
                                        # start watching the socket
  $kernel->select($socket_handle, 'read', 'write');
                                        # return something interesting
  return gmtime();
}

#------------------------------------------------------------------------------
# Stop the session.

sub connection_stop {
  my $heap = $_[HEAP];
                                        # goodbye, world!
  my $peer_host = $heap->{'host'};
  my $peer_port = $heap->{'port'};
  print "Stopped chargen connection with $peer_host:$peer_port\n";
}

#------------------------------------------------------------------------------
# Events that arrive without a corresponding handler are rerouted to
# _default.  This _default handler just displays the nature of the
# unknown event.  It exists in this program mainly for debugging.

sub connection_default {
  my ($state, $params) = @_[ARG0, ARG1];

  print "The chargen connection has received a _default event.\n";
  print "The original event was $state, with the following parameters:",
        join('; ', @$params), "\n";
                                        # returns 0 in case it was a signal
  return 0;
}

#------------------------------------------------------------------------------
# The client is sending some information.  Read and discard it.

sub connection_read {
  my $handle = $_[ARG0];
  1 while (sysread($handle, my $buffer = '', 32000));
}

#------------------------------------------------------------------------------
# The client connection can accept more information.  Write a line of
# generated characters to it.

sub connection_write {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];
                                        # create a chargen line
  my $output_string = join('',
                           map { chr }
                           ($heap->{'char'} .. ($heap->{'char'}+71))
                          ) . "\x0D\x0A";
  $output_string =~ tr[\x7F-\xDD][\x20-\x7E];
                                        # increment the line's start character
  $heap->{'char'} = 32 if (++$heap->{'char'} > 126);
                                        # write the line (blocks!)
  my ($offset, $to_write) = (0, length($output_string));
  while ($to_write) {
    my $sub_wrote = syswrite($handle, $output_string, $to_write, $offset);
    if ($sub_wrote) {
      $offset += $sub_wrote;
      $to_write -= $sub_wrote;
    }
    elsif ($!) {
                                        # close session on error
      print( "The chargen connection has encountered write error ",
             ($!+0), ": $!\n"
           );
      $kernel->select($handle);
      last;
    }
  }
}

#------------------------------------------------------------------------------
# The session received a signal.  Display the signal, and tell the
# kernel that it can stop the session.

sub connection_signal {
  my $signal_name = $_[ARG0];
  print "The chargen connection received SIG$signal_name\n";
}

#==============================================================================
# This is a basic chargen server, as rendered in POE states.  The
# original example had the subs as inlined anonymous references, but
# it's been pulled apart for clarity.

#------------------------------------------------------------------------------
# Handle POE's standard _start event.  This creates and begins
# listening on a TCP server socket.

sub server_start {
  my $kernel = $_[KERNEL];
                                        # hello, world!
  print "The chargen server is starting on port $chargen_port ...\n";

  # Watch for signals.  Note: SIGPIPE is not considered to be a
  # terminal signal.  The session will not be stopped if SIGPIPE is
  # unhandled.  The signal handler is registered for SIGPIPE just so
  # we can see it occur.

  $kernel->sig('INT', 'signal');
  $kernel->sig('PIPE', 'signal');
                                        # create the listening socket
  my $listener = IO::Socket::INET->new(
    LocalPort => $chargen_port,
    Listen    => 5,
    Proto     => 'tcp',
    Reuse     => 'yes',
  );
                                        # move to 'accept' when read-okay
  if ($listener) {
    $kernel->select_read($listener, 'accept');
  }
  else {
    print "The chargen server could not listen on $chargen_port: $!\n";
  }
}

#------------------------------------------------------------------------------
# Stop the server when POE's standard _stop event arrives.  Normally
# this would garbage-collect the session's heap, but this simple
# session doesn't need it.

sub server_stop {
  print "The chargen server has stopped.\n";
}

#------------------------------------------------------------------------------
# Take note when chargen connection come and go.

my %english = ( gain => 'gained', lose => 'lost', create => 'created' );

sub server_child {
  my ($direction, $child, $return) = @_[ARG0, ARG1, ARG2];

  print "The chargen server has $english{$direction} a child session.\n";
  if ($direction eq 'create') {
    print "The child session's _start state returned: $return\n";
  }
}

#------------------------------------------------------------------------------
# Events that arrive without a corresponding handler are rerouted to
# _default.  This _default handler just displays the nature of the
# unknown event.  It exists in this program mainly for debugging.

sub server_default {
  my ($state, $params) = @_[ARG0, ARG1];

  print "The chargen server has received a _default event.\n";
  print "The original event was $state, with the following parameters:",
        join('; ', @$params), "\n";
                                        # returns 0 in case it was a signal
  return 0;
}

#------------------------------------------------------------------------------
# This event handler is called when the listening socket becomes ready
# for reading.  It accepts the incoming connection, gathers some
# information about it, and spawns a new session to handle I/O.

sub server_accept {
  my ($kernel, $session, $handle) = @_[KERNEL, SESSION, ARG0];

  print "The chargen server detected an incoming connection.\n";
                                        # accept the handle
  my $connection = $handle->accept();
  if ($connection) {
                                        # gather information about the socket
    my $peer_host = $connection->peerhost();
    my $peer_port = $connection->peerport();
                                        # create a session to handle I/O
    my $new = POE::Session->create(
      inline_states => {
        _start     => \&connection_start,
        _stop      => \&connection_stop,
        _default   => \&connection_default,
        'read'     => \&connection_read,
        'write'    => \&connection_write,
        signal     => \&connection_signal,
      },

      # ARG0, ARG1 and ARG2
      args => [ $connection, $peer_host, $peer_port ]
    );
  }
  else {
    if ($! == EAGAIN) {
      print "Incoming chargen server connection not ready... try again!\n";
      $kernel->yield('accept', $handle);
    }
    else {
      print "Incoming chargen server connection failed: $!\n";
    }
  }
}

#------------------------------------------------------------------------------
# This sub is called whenever an "important" signal arrives.  It just
# displays details about the signals it receives.

sub server_signal {
  my $signal_name = $_[ARG0];
  print "The chargen server received SIG$signal_name\n";
  return 0;
}

#==============================================================================
# This is a basic line-based client, as rendered in POE states.  The
# original example had the subs as inlined anonymous references, but
# it's been pulled apart for clarity.

#------------------------------------------------------------------------------
# Start the client.  It registers signal handlers and tries to
# establish a connection.

sub client_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  print "The chargen client is connecting to port $chargen_port ...\n";
                                        # register SIGINT and SIGPIPE handlers
  $kernel->sig('INT', 'signal');
  $kernel->sig('PIPE', 'signal');
                                        # so it knows when to stop
  $heap->{'lines read'} = 0;
                                        # try to make a connection
  my $socket = IO::Socket::INET->new(
    PeerHost => 'localhost',
    PeerPort => $chargen_port,
    Proto    => 'tcp',
    Reuse    => 'yes',
  );
                                        # start reading if connected
  if ($socket) {
    print "The chargen client has connected to port $chargen_port.\n";
    $kernel->select_read($socket, 'read');
  }
  else {
    print "The chargen client could not connect to $chargen_port: $!\n";
  }
}

#------------------------------------------------------------------------------
# Handle POE's standard _stop event.

sub client_stop {
  print "\nThe chargen client has stopped.\n";
}

#------------------------------------------------------------------------------
# Events that arrive without a corresponding handler are rerouted to
# _default.  This _default handler just displays the nature of the
# unknown event.  It exists in this program mainly for debugging.

sub client_default {
  my ($state, $params) = @_[ARG0, ARG1];

  print "The chargen client has received a _default event.\n";
  print "The original event was $state, with the following parameters:",
        join('; ', @$params), "\n";
                                        # returns 0 in case it was a signal
  return 0;
}

#------------------------------------------------------------------------------
# This handler is called when the client can read.  It displays
# whatever was read, exiting when either a few lines have displayed or
# an error has occurred.

sub client_read {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];
                                        # read a chunk of input
  my $read_count = sysread($handle, my $buffer = '', 512);
                                        # display it
  if ($read_count) {
    print $buffer;
                                        # count lines; exit if 5 or more
    $heap->{'lines read'} += ($buffer =~ s/(\x0D\x0A)/$1/g);
    if ($heap->{'lines read'} > 5) {

      # The read select is the only part of this session that
      # generates events.  When it is removed, the session runs out of
      # things to do and stops.

      $kernel->select($handle);
    }
  }
                                        # stop if there was trouble reading
  else {
    $kernel->select($handle);
  }
}

#------------------------------------------------------------------------------
# This sub is called whenever an "important" signal arrives.  It just
# displays details about the signals it receives.

sub client_signal {
  my $signal_name = $_[ARG0];
  print "The chargen client received SIG$signal_name\n";
  return 0;
}

#==============================================================================
# Start a server and a client, and run indefinitely.

POE::Session->create(
	inline_states => {
		_start     => \&server_start,
		_stop      => \&server_stop,
		_default   => \&server_default,
		_child     => \&server_child,
		'accept'   => \&server_accept,
		signal     => \&server_signal,
	},
);

POE::Session->create(
	inline_states => {
		_start     => \&client_start,
		_stop      => \&client_stop,
		_default   => \&client_default,
		'read'     => \&client_read,
		signal     => \&client_signal,
	},
);

POE::Kernel->run();

exit;
