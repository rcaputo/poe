#!/usr/bin/perl -w
# $Id$

# This program is half of a test suite for POE::Filter::Reference.  It
# implements a client that thaws referenced data and sends it to a
# server for processing.

# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Rewritten to use POE to exercise Filter::Reference::put()
# Revised for POE 0.06 by Rocco Caputo <troc@netrus.net>

use strict;
use lib '..';
use Socket;

use POE qw(Wheel::SocketFactory
           Wheel::ReadWrite Driver::SysRW Filter::Reference
          );

###############################################################################
# This is an all-in-one reference sender.  It starts out using a
# SocketFactory wheel to make a connection, then switches to a
# ReadWrite wheel to process data once the connection is made.  It is
# not a good example of non-blocking client architecture, as it has a
# potentially long busy loop.

#------------------------------------------------------------------------------
# This is a standardized way to create clients.

sub client_create {
  new POE::Session( _start    => \&client_start,
                    _stop     => \&client_stop,
                    connected => \&client_connected,
                    error     => \&client_error,
                    received  => \&client_receive,
                    flushed   => \&client_flushed
                  );
}

#------------------------------------------------------------------------------
# Try to establish a connection to a reference server when POE signals
# that everything is set to start.

sub client_start {
  my $heap = $_[HEAP];

  print "Client starting.\n";
                                        # create a socket factory
  $heap->{'wheel'} = new POE::Wheel::SocketFactory
    ( RemoteAddress  => '127.0.0.1',    # connect to this address
      RemotePort     => 31338,          # connect to this port (eleet++)
      SuccessState   => 'connected',    # generating this event on success
      FailureState   => 'error'         # generating this event on failure
    );
}

#------------------------------------------------------------------------------
# Acknowledge that the client has stopped.

sub client_stop {
  print "Client stopped.\n";
}

#------------------------------------------------------------------------------
# This state is invoked when a connection has been established.  It
# replaces the SocketFactory wheel with a ReadWrite wheel, and sends
# some data to the server.  The server doesn't send a response, but
# this watches for one anyway.

sub client_connected {
  my ($heap, $socket) = @_[HEAP, ARG0];

  print "Client connected.\n";
                                        # become a reader/writer
  $heap->{'wheel'} = new POE::Wheel::ReadWrite
    ( Handle       => $socket,                    # read/write on this handle
      Driver       => new POE::Driver::SysRW,     # using sysread and syswrite
      Filter       => new POE::Filter::Reference(undef,1), # parsing refs
      InputState   => 'received',                 # generating this on input
      ErrorState   => 'error',                    # generating this on error
      FlushedState => 'flushed',                  # generating this on flush
    );

  # Send objects.  If there are command-line arguments, the first one
  # is considered to be the number of objects to send.  Subsequent
  # arguments are sent verbatim.  They are queued in a big loop and
  # sent when this state returns control back to the kernel.  As a
  # result, there may be an initial delay before the data is sent.

  # Oh, and this is bad form.  Normal code should set up a tight event
  # loop to send the data, letting the kernel process other pending
  # events.

  if (@ARGV) {
                                        # add a field for a sequence number
    push @ARGV, '0' x (length($ARGV[0]));
                                        # send $ARGV[0] array references
    for (my $i = 0; $i < $ARGV[0]; $i++) {
                                        # increment the sequence number
      $ARGV[-1]++;
      $heap->{'wheel'}->put( [ @ARGV, time ] );
    }
  }

  # Otherwise, if there are no command-line arguments, send a blessed
  # hashref, a blessed arrayref, and an unblessed scalar reference.

  else {
    $heap->{'wheel'}->put
      ( (bless { site => 'wdb', id => 1 }, 'kristoffer'),
        (bless [ qw(one two three four) ], 'roch'),
        \ "this is an unblessed scalar thingy"
      );
  }
}

#------------------------------------------------------------------------------
# There was an I/O error.  Display the error's nature, and stop the
# session.

sub client_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  print "The client has encountered $operation error $errnum: $errstr\n";
  delete $heap->{'wheel'};
}

#------------------------------------------------------------------------------
# The server doesn't send anything back, but an event handler is
# defined here anyway.  In the current refsender/refserver design, it
# would never be called.

sub client_receive {
  my $reference = $_[ARG0];

  # Remember, this function is not normally called.  If you want to
  # reuse refsender.perl for something that speaks bi-directionally,
  # you'll have to also not delete $heap->{'wheel'} from within the
  # &client_flushed event handler.

  print "The client recevied a reference: $reference\n";
}

#------------------------------------------------------------------------------
# When all the queued output has been flushed to the socket, it is
# time to leave.

sub client_flushed {
  my $heap = $_[HEAP];
  print "All references were sent.  Bye!\n";

  # Note: refserver.perl doesn't send a reply.  When the wheel
  # indicates that all the references were flushed, we delete the
  # wheel so the client can stop.

  delete $heap->{'wheel'};
}

###############################################################################
# Create a client, and run things until it's time to stop.

&client_create();
$poe_kernel->run();

exit;
