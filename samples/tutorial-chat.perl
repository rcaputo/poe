#!perl -w -I..
# $Id$

=pod //////////////////////////////////////////////////////////////////////////

Okay... how to write a program using POE.  First we need a program to
write.  How about a simple chat server?  Ok!

First perform some preliminary setup.  Turn on strict, and import the
things we need.  That will be Socket, for the socket constants and
address manipulation; and some POE classes.  All the POE classes get
POE:: prepended to them when used along with POE.pm itself.  So, the
classes we use here:

POE::Wheel::SocketFactory, to create the sockets.

POE::Wheel::ReadWrite, to send and receive on the client sockets.

POE::Driver::SysRW, to read and write with sysread() and syswrite().

POE::Filter::Line, to process input and output as lines.

Here we go:

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

use strict;
use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);

=pod //////////////////////////////////////////////////////////////////////////

Now we need to create the listening server and wait for connections.
First we define the subroutines that will handle the events, and then
we create the POE::Session that maps events to subroutines.

But first a quick note about event handler parameters.  Every event
handler gets its parameters in some strange order.  Actually, they all
get parameters in the same order, but the order changes from time to
time (usually between versions).  So Rocco and Artur benchmarked a
bunch of different ways to pass parameters where the order makes no
difference.  The least slowest way to do this-- which still is slower
than plain list assignment-- was to use an array slice.

So we came up with some constants for parameter indices into @_, and
exported them from POE::Session (which is automatically included when
you use POE).  Now you can say C<my ($heap, $kernel, $parameter) =
@_[HEAP, KERNEL, ARG0]>, and it will continue to work even if new
parameters are added.  And if parameters are ever removed, well, it
will break at compile time instead of causing sneaky runtime problems.

So anyway, some of the important parameter offsets and what they do:

  KERNEL is a reference to the POE kernel (event loop and services
  object).

  SESSION is a reference to the current session.

  HEAP is an anonymous hashref that a session can use to hold its own
  "global" variables.

  FROM is the session that sent the event.

  ARG0..ARG9 are the first ten event parameters.  If you need more
  than that, you can either use ARG9+1.. or consider passing
  parameters as an arrayref.  Array references would be faster anyway.

Now about the SocketFactory.  A SocketFactory is a factory that
creates... sockets.  See?  Anyway, the socket factory creates sockets,
but it does not return them.  Instead, it waits until the sockets are
ready, and then it sends a "this socket is ready" sort of success
event.  The socket itself is sent as a parameter (ARG0) of the success
event.  And because this is non-blocking (event during connect), the
program can keep working on other things while it waits.

There is more magic.  For listening sockets, it sends the "this socket
is ready" event whenever a connection is successfully accepted.  And
the socket that accompanies the event is the accepted one, not the
listening one.  This makes writing servers real easy, because all the
work between "create this server socket" and "here's your client
connection" is taken care of inside the SocketFactory object.

So here is the server stuff:

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# server_start is the server session's "_start" handler.  It's called
# when POE says the server session is ready to start.  If you're
# familiar with objects, it's sort of like a constructor, only it says
# the object has been constructed already and is ready to be used.  So
# I guess it can be called a "constructed" instead. :)

sub server_start {
  my $heap = $_[HEAP];

  # Create a listening INET/tcp socket.  Store a reference to the
  # SocketFactory wheel in the session's heap.  When the session
  # stops, and the heap is destroyed, the SocketFactory reference
  # count drops to zero, and Perl destroys it for us.  Then it does a
  # little "close the socket" dance inside, and everything is tidy.

  $heap->{listener} = new POE::Wheel::SocketFactory
    ( SocketDomain   => AF_INET,         # create it in the AF_INET domain
      SocketType     => SOCK_STREAM,     # create stream sockets
      SocketProtocol => 'tcp',           # using the tcp protocol
      BindAddress    => INADDR_ANY,      # bound to port 30023 of all addresses
      BindPort       => 30023,
      Reuse          => 'yes',           # reuse the port right away
      ListenQueue    => 5,               # listen, with a 5-socket queue
      SuccessState   => 'event_success', # event to send on connection
      FailureState   => 'event_failure'  # event to send on error
    );

  print "SERVER: started listening on port 30023\n";
}

# server_stop is the server session's "_stop" handler.  It's called
# when POE says the session is about to die.  Again, OO folks could
# consider it a destructor.  Or and about-to-be-destructed thing.

sub server_stop {
  
  # Log the server's stopping...

  print "SERVER: stopped.\n";

  # Just make sure the socket factory is destroyed.  This shouldn't
  # really be necessary, but it shows how to use event handler
  # parameters without first using an array slice.

  delete $_[HEAP]->{listener};
}

# server_accept is the server session's "accept" handler.  When a
# session arrives, it's called to do something with the socket that
# was created by accept().

sub server_accept {
  my ($accepted_socket, $peer_address, $peer_port) = @_[ARG0, ARG1, ARG2];

  # The first parameter to SocketFactory's success event is a handle
  # to an established socket (in this case, an accepted one).  For
  # accepted handles, the second and third parameters are the client
  # side's address and port (direct from the accept call's return
  # value).  Oh, but only if it's an AF_INET socket.  They're undef
  # for AF_UNIX sockets, because the PCB says accept's return value is
  # undefined for those.

  # Anyway, translate the peer address to something human-readable,
  # and log the connection.

  $peer_address = inet_ntoa($peer_address);
  print "SERVER: accepted a connection from $peer_address : $peer_port\n";

  # So, we start a new POE::Session to handle the connection.  This is
  # equivalent to forking off a child process to handle a connection,
  # but it stays in the same process.  So it's more like threading, I
  # suppose.

  new POE::Session( _start      => \&chat_start, # _start event handler
                    _stop       => \&chat_stop,  # _stop event handler
                    line_input  => \&chat_input, # input event handler
                    io_error    => \&chat_error, # error event handler
                    out_flushed => \&chat_flush, # flush event handler
                    hear        => \&chat_heard, # someone said something

                    # To pass arguments to a session's _start handler,
                    # include them in an array reference.  For
                    # example, the following array reference causes
                    # $accepted_handle, $peer_addr and $peer_port to
                    # arrive at the chat session's _start event
                    # handler as ARG0, ARG1 and ARG2, respectively.

                    [ $accepted_socket, $peer_address, $peer_port ]
                  );

  # That's all there is to it.  Take the handle, and start a session
  # to cope with it.  Easy stuff.
}

# server_error is the server session's "error" handler.  If something
# goes wrong with creating, reading or writing sockets, this gets
# called to cope with it.

sub server_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  # The first three parameters to SocketFactory's error event are the
  # operation that failed, and the numeric and string versions of $!.

  # So log the error already...

  print "SERVER: $operation error $errnum: $errstr\n";

  # And destroy the socket factory.  Destroying it also closes down
  # the listening socket.  After that, this session will run out of
  # things to do and stop.

  delete $heap->{listener};
}

=pod //////////////////////////////////////////////////////////////////////////

This section of the program is the actual chat management.  For the
sake of the tutorial, it is just a hash to keep track of connections
and a subroutine to distribute messages to everyone.

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# This is just a hash of connections, keyed on the connection's
# session reference.  Each element references a record holding the
# un-stringified session reference and maybe some other information
# about the user on the other end of the socket.
#
# Currently, it's [ $session, $user_nickname ].

my %connected_sessions;

# This function takes a kernel reference, the speaker's session, and
# whatever it is that the speaker said.  It formats a message, and
# sends it to everyone listed in %connected_sessions.

sub say {
  my ($kernel, $who) = (shift, shift);
  my $what = join('', @_);

  # Translate the speaker's session to their nickname.

  $who = $connected_sessions{$who}->[1];

  # Send a copy of what they said to everyone.

  foreach my $session (values(%connected_sessions)) {

    # Call the "hear" event handler for each session, with "<$who>
    # $what" in ARG0.  Essentially, this tells them to hear what the
    # user said.

    # It uses call() here instead of post() because of the way
    # departing users are handled.  With post, you get situations
    # where the event is delivered after the user's wheel is gone,
    # leading to runtime errors when the session tries to send the
    # message.  I wimped out and used call() instead of coding the
    # session right; it's okay for just this sample code.

    $kernel->call($session->[0], "hear", "<$who> $what");
  }
}

=pod //////////////////////////////////////////////////////////////////////////

Now we need to handle the accepted client connections.

A quick recap of where the accepted socket currently is.  It was
accepted by the SocketFactory, and passed to server_accept with the
"we got a connection" event.  Then server_accept handed it off to a
new POE::Session as a parameter to its _start event.  The _start event
(and the handle, and the peer address and port) will then be delivered
to chat_start as ARG0, ARG1 and ARG2.

So anyway, read input from the client connection, process it somehow,
and generate responses.  Here we are at chat_start...

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# Okay... chat_start is the chat session's "_start" handler.  It's
# called after the new POE::Session has been set up within POE.  This
# is POE's way of saying "okay, you're cleared for take off".

sub chat_start {
  my ($heap, $session, $accepted_socket, $peer_addr, $peer_port) =
    @_[HEAP, SESSION, ARG0, ARG1, ARG2];

  # Start reading and writing on the accepted socket handle, parsing
  # I/O as lines, and generating events for input, error, and output
  # flushed conditions.

  $heap->{readwrite} = new POE::Wheel::ReadWrite
    ( Handle       => $accepted_socket,       # read/write on this handle
      Driver       => new POE::Driver::SysRW, # using sysread and syswrite
      Filter       => new POE::Filter::Line,  # filtering I/O as lines
      InputState   => 'line_input',     # generate line_input on input
      ErrorState   => 'io_error',       # generate io_error on error
      FlushedState => 'out_flushed',    # geterate out_flushed on flush
    );

  # Now that the session can read from and write to the socket, log
  # the client into the chat hash, and say hello to everyone.

  $connected_sessions{$session} = [ $session, "$peer_addr:$peer_port" ];
  &say($_[KERNEL], $session, '[has joined chat]');

  # Oh, and log the client session's start.

  print "CLIENT: $peer_addr:$peer_port connected\n";
}

# And this is the chat session's "destructor", called by POE when the
# session is about to stop.

sub chat_stop {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # If this session still is connected (that is, it wasn't
  # disconnected in an error event handler or something), then tell
  # everyone the person has left.

  if (exists $connected_sessions{$session}) {

    # Log the disconnection.

    print "CLIENT: $connected_sessions{$session}->[1] disconnected.\n";

    # And say goodbye to everyone else.
      
    &say($kernel, $session, '[has left chat]');
    delete $connected_sessions{$session};
  }

  # And, of course, close the socket.  This isn't really necessary
  # here, but it's nice to see.

  delete $heap->{readwrite};
}

# This is what the ReadWrite wheel calls when the client end of the
# socket has sent a line of text.  The actual text is in ARG0.

sub chat_input {
  my ($kernel, $session, $input) = @_[KERNEL, SESSION, ARG0];

  # Preprocess the input, backspacing over backspaced/deleted
  # characters.  It's just a nice thing to do for people using
  # character-mode telnet.

  1 while ($input =~ s/[^\x08\x7F][\x08\x7F]//g);
  $input =~ tr[\x08\x7F][]d;

  # Parse the client's input for commands, and handle them.  For this
  # little demo/tutorial, we only bother with one command.

  # The /nick command.  This changes the user's nickname.

  if ($input =~ m!^/nick\s+(.*?)\s*$!i) {
    my $nick = $1;
    $nick =~ s/\s+/ /g;

    &say($kernel, $session, "[is now known as $nick]");
    $connected_sessions{$session} = [ $session, $nick ];
  }

  # Anything that isn't a recognized command is sent as a spoken
  # message.

  else {
    &say($kernel, $session, $input);
  }
}

# And if there's an I/O error (such as error 0: they disconnected),
# the chat_error handler is called to do something about it.

sub chat_error {
  my ($kernel, $session, $operation, $errnum, $errstr) =
    @_[KERNEL, SESSION, ARG0, ARG1, ARG2];

  # Error 0 is not an error.  It just signals EOF on the socket.  So
  # prettify the error string.

  unless ($errnum) {
    $errstr = 'disconnected';
  }

  # Log the error...

  print( "CLIENT: ", $connected_sessions{$session}->[1],
         " got $operation error $errnum: $errstr\n"
       );

  # Log the user out of the chat server with an error message.

  &say($kernel, $session, "[$operation error $errnum: $errstr]");
  delete $connected_sessions{$session};

  # Delete the ReadWrite wheel.  This closes the handle it's using...
  # unless you have a reference to it somewhere else.  In that case,
  # it just leaks a filehandle 'til you close it yourself.

  delete $_[HEAP]->{readwrite};
}

# This handler is called every time the ReadWrite's output queue
# becomes empty.  It can be used to stop the session after a "quit"
# message has been sent to client.  It can also be used to send a
# prompt or something.

sub chat_flush {
  # Actually, I don't really care at this point.  I'm tired of writing
  # comments already, and whatever this is going to do will have to be
  # defined later.

  # It's wasteful to leave this here.  Removing the FlushedState
  # parameter from the ReadWrite wheel will prevent this event handler
  # from being called.  But I'm leaving it this way as an example.
}

# And finally, this is the "hear" event handler.  It's called by the
# &say function whenever someone in the chat server says something.
# ARG0 is a fully-formatted message, suitable for dumping to a socket.

sub chat_heard {
  my ($heap, $what_was_heard) = @_[HEAP, ARG0];

  # Put the message in the ReadWrite wheel's output queue.  All the
  # line-formatting and buffered I/O stuff happens inside the wheel,
  # because its constructor told it to do that (Filter::Line).

  $heap->{readwrite}->put($what_was_heard);

  # And the kernel and the wheel take care of sending it.  Cool, huh?
}

=pod //////////////////////////////////////////////////////////////////////////

And finally, start the server and run the event queue.

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

new POE::Session( _start        => \&server_start,  # server _start handler
                  _stop         => \&server_stop,   # server _stop handler
                  event_success => \&server_accept, # server connection handler
                  event_failure => \&server_error,  # server error handler
                );

# POE::Kernel, automagically used when POE is used, exports
# $poe_kernel.  It's a reference to the process' global kernel
# instance, which mainly is used to start the kernel.  Like now:

$poe_kernel->run();

# POE::Kernel::run() won't exit until the last session stops.  That
# usually means the program is done with whatever it was doing, and we
# can exit now.

exit;
