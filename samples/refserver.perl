#!perl -w -I..
# $Id$

# This program is half of a test suite for POE::Filter::Reference.  It
# implements a server that accepts frozen data, thaws it, and displays
# some information about it.  It also tests aliased "daemon" sessions,
# as well as a few other things.

# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Revised for 0.06 by Rocco Caputo <troc@netrus.net>

use strict;
use Socket;

use POE qw(Wheel::ListenAccept Wheel::ReadWrite Wheel::SocketFactory
           Driver::SysRW Filter::Reference
          );

sub DEBUG { 0 }

###############################################################################
# Responder is an aliased session that processes data from Daemon
# instances.

#------------------------------------------------------------------------------
# This is just a convenient way to create responders.

sub responder_create {
  new POE::Session( _start   => \&responder_start,
                    respond  => \&responder_respond,
                  );
}

#------------------------------------------------------------------------------
# Accept POE's standard _start message, and start the responder.

sub responder_start {
  my $kernel = $_[KERNEL];

  DEBUG && print "Responder started.\n";
                                        # allow it to be called by name
  $kernel->alias_set('Responder');
}

#------------------------------------------------------------------------------
# Daemons give requests to this state for processing.

sub responder_respond {
  my $request = $_[ARG0];

  print "Responder @ " . time . ": $request = ";
  if ($request =~ /(^|=)HASH\(/) {
    print "{ ", join(', ', %$request), " }\n";
  }
  elsif ($request =~ /(^|=)ARRAY\(/) {
    print "( ", join(', ', @$request), " )\n";
  }
  elsif ($request =~ /(^|=)SCALAR\(/) {
    print $$request, "\n";
  }
  else {
    print "(unknown reference type)\n";
  }
}

###############################################################################
# Daemon instances are created by the listening session to handle
# connections.  They receive one or more thawed references, and pass
# them to the running Responder session for processing.

#------------------------------------------------------------------------------
# This is just a convenient way to create daemons.

sub daemon_create {
  my $handle = $_[0];

  DEBUG && print "Daemon session created.\n";

  new POE::Session( _start => \&daemon_start,
                    _stop  => \&daemon_shutdown,
                    client => \&daemon_client,
                    error  => \&daemon_error,
                                        # ARG0
                    [ $handle ]
                  );
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and begin processing data.

sub daemon_start {
  my ($heap, $handle) = @_[HEAP, ARG0];
                                        # start reading and writing
  $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $handle,                    # on this handle
      Driver     => new POE::Driver::SysRW,     # using sysread and syswrite
      Filter     => new POE::Filter::Reference, # and parsing I/O as references
      InputState => 'client',           # generate this event on input
      ErrorState => 'error',            # generate this event on error
    );
}

#------------------------------------------------------------------------------
# This state is invoked for each reference received by the session's
# ReadWrite wheel.

sub daemon_client {
  my ($kernel, $request) = @_[KERNEL, ARG0];
  DEBUG && print "Daemon received a reference.\n";
                                        # call the Responder daemon to process
  $kernel->call('Responder', 'respond', $request);
}

#------------------------------------------------------------------------------
# This state is invoked for each error encountered by the session's
# ReadWrite wheel.

sub daemon_error {
  my ($heap, $operation, $errnum, $errstr) =
    @_[HEAP, ARG0, ARG1, ARG2];

  if ($errnum) {
    DEBUG && print "Daemon encountered $operation error $errnum: $errstr\n";
  }
  else {
    DEBUG && print "The daemon's client closed its connection.\n";
  }
                                        # either way, shut down
  delete $heap->{wheel_client};
}

#------------------------------------------------------------------------------
# Process POE's standard _stop event by shutting down.

sub daemon_shutdown {
  my $heap = $_[ARG0];
  DEBUG && print "Daemon has shut down.\n";
  delete $heap->{wheel_client};
}

###############################################################################
# This is a simple reference server.

#------------------------------------------------------------------------------
# This is just a convenient way to create servers.  To be useful in
# multi-server situations, it probably should accept a bind address
# and port.

sub server_create {
  new POE::Session( _start   => \&server_start,
                    error    => \&server_error,
                    'accept' => \&server_accept
                  );
}

#------------------------------------------------------------------------------
# Accept POE's standard _start event, and set up the listening socket
# factory.

sub server_start {
  my $heap = $_[HEAP];

  DEBUG && print "Server starting.\n";
                                        # create a socket factory
  $heap->{wheel} = new POE::Wheel::SocketFactory
    ( BindPort       => '31338',        # on the eleet++ port
      Reuse          => 'yes',          # and allow immediate reuse of the port
      SuccessState   => 'accept',       # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );
}

#------------------------------------------------------------------------------
# Log server errors, but don't stop listening for connections.  If the
# error occurs while initializing the factory's listening socket, it
# will exit anyway.

sub server_error {
  my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
  DEBUG && print "Server encountered $operation error $errnum: $errstr\n";
}

#------------------------------------------------------------------------------
# The socket factory invokes this state to take care of accepted
# connections.

sub server_accept {
  my ($handle, $peer_host, $peer_port) = @_[ARG0, ARG1, ARG2];

  DEBUG &&
    print "Server connection from ", inet_ntoa($peer_host), " $peer_port\n";
                                        # give the connection to a daemon
  &daemon_create($handle);
}

###############################################################################
# Set up a responder and a server, and have POE run them until they
# stop.

&responder_create();
&server_create();

$poe_kernel->run();

exit;
