#!/usr/bin/perl -w -I..
# $Id$

# If wheels make you squeamish, see selects.perl.  It is about the
# same program, but it doesn't use wheels.

# So after writing selects.perl, it was determined that certain
# behaviors (namely listen/accept and read/write) were generic enough
# to relegate to classes.  Additionally, it was decided that I/O could
# be broken into things that read and write streams (Drivers) and
# things that translate between streams and low-level protocols
# (Filters).  POE's I/O layer evolved from these realizations, and
# this test was written to prove the concepts.

# Wheels, Drivers and Filters were still new at this point.
# POE::Wheel::SocketFactory had not been conceived at this point, so
# this program still relies on IO::Socket.

use strict;

use POE qw(Wheel::ListenAccept Wheel::ReadWrite Driver::SysRW Filter::Line);
use IO::Socket;

my $rot13_port = 32000;

#==============================================================================
# The session_* functions implement a line-based rot13 server session.
# The session reads lines from the client and responds with the lines
# translated through a rot13 filter.

#------------------------------------------------------------------------------
# Handle POE's standard _start event by starting the read/write wheel
# and welcoming the client.

sub session_start {
  my ($kernel, $heap, $accepted_handle, $peer_host, $peer_port) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
                                        # sysread/syswrite/line-filter
  $heap->{'wheel'} = new POE::Wheel::ReadWrite
    ( Handle => $accepted_handle,         # read/write this handle
      Driver => new POE::Driver::SysRW(), # with sysread and syswrite
      Filter => new POE::Filter::Line(),  # and parse the data as lines
      InputState => 'line_input',         # emitting this event for each line
      ErrorState => 'line_error',         # and this event for each error
    );
                                        # remember the host/port for later
  $heap->{'host'} = $peer_host;
  $heap->{'port'} = $peer_port;
                                        # newlines are added automatically
  $heap->{'wheel'}->put("Greetings, $peer_host $peer_port!  Type some text!");
                                        # log the connection to stdout
  print "> begin rot-13 session with $peer_host $peer_port\n";
}

#------------------------------------------------------------------------------
# Handle POE's standard _stop event.  This just logs that the
# connection has closed.

sub session_stop {
  my $heap = $_[HEAP];
  print "< cease rot-13 session with $heap->{'host'} $heap->{'port'}\n";
}

#------------------------------------------------------------------------------
# Handle input from the client.  This is called whenever a 'Filter'
# defined chunk of input is received.  In this program's case, it's
# called for each line.

sub session_input {
  my ($heap, $line) = @_[HEAP, ARG0];
                                        # rot-13 the input
  $line =~ tr[a-zA-Z][n-za-mN-ZA-M];
                                        # give the new version back
  $heap->{'wheel'}->put($line);
}

#------------------------------------------------------------------------------
# When errors occur, they are given to this handler.  It takes the
# operation being performed (read, write, accept, connect, etc.) and
# the numeric and stringified error code.  The error codes are passed
# in this way because $! may have changed between the event's posting
# time and when it was dispatched to the handler.

sub session_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
                                        # log the error (if it's an error)
  if ($errnum) {
    print "* $operation error $errnum: $errstr\n";
  }
                                        # remove the wheel (stops the session)
  delete $heap->{'wheel'};
}

#==============================================================================
# The server_* functions implement a simple TCP server.  It spawns off
# new sessions to handle connections.

#------------------------------------------------------------------------------
# Handle POE's standard _start event by creating a listening socket
# and a listen/accept wheel to accept connections.

sub server_start {
  my $heap = $_[HEAP];
                                        # create the listening socket
  my $listener = new IO::Socket::INET
    ( LocalPort => $rot13_port,
      Listen    => 5,
      Proto     => 'tcp',
      Reuse     => 'yes',
    );
                                        # if okay, begin listening on it
  if ($listener) {
    $heap->{'wheel'} = new POE::Wheel::ListenAccept
      ( Handle      => $listener,
        AcceptState => 'accept_success',
        ErrorState  => 'accept_error'
      );

    print "= rot-13 server listening on port $rot13_port\n";
  }
                                        # otherwise, nothing will happen
  else {
    warn "* rot13 server didn't start: $!";
  }
}

#------------------------------------------------------------------------------
# When POE signals that this session needs to stop, log it.

sub server_stop {
  print "= rot-13 server stopped\n";
}

#------------------------------------------------------------------------------
# This handles the event generated by the ListenAccept wheel when an
# error occurs.  $operation is the function that failed, and the other
# parameters explain why the failure occurred.

sub server_error {
  my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
                                        # log the error
  print "* $operation error $errnum: $errstr\n";
}

#------------------------------------------------------------------------------
# Handle the ListenAccept event that signals when a connection has
# been successfully accepted.  This spawns a new session to process
# the client's request.

sub server_accept {
  my $accepted_handle = $_[ARG0];

  my ($peer_host, $peer_port) =
    ( $accepted_handle->peerhost(),
      $accepted_handle->peerport()
    );

  new POE::Session( _start => \&session_start,
                    _stop => \&session_stop,
                    line_input => \&session_input,
                    line_error => \&session_error,
                                        # ARG0, ARG1, ARG2
                    [ $accepted_handle, $peer_host, $peer_port ]
                  );
}

#==============================================================================
# Start the server, and run the kernel until it's time to stop.

new POE::Session( _start => \&server_start,
                  _stop => \&server_stop,
                  accept_success => \&server_accept,
                  accept_error => \&server_error,
                );

$poe_kernel->run();

exit;
