#!/usr/bin/perl -w

# This program tests the high and low watermarks.  It merges the
# wheels from wheels.perl and the chargen service from selects.perl to
# create a wheel-based chargen service.

use strict;
use lib '../lib';
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);

my $chargen_port = 32100;

#==============================================================================
# This is a simple TCP server.  It answers connections and passes them
# to new chargen service sessions.

package Chargen::Server;
use POE::Session;

# Create a new chargen server.  This doesn't create a real object; it
# just spawns a new session.  OO purists will hate me for this.
sub new {
  POE::Session->create
    ( inline_states =>
      { _start   => \&poe_start,
        accepted => \&poe_accepted,
        error    => \&poe_error,
      }
    );
  undef;
}

# The Session has been set up within POE::Kernel, so it's safe to
# begin working.  Create a socket factory to listen for new
# connections.
sub poe_start {
  $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new
    ( SuccessEvent => 'accepted',
      FailureEvent => 'error',
      BindPort     => $chargen_port,
      Reuse        => 'yes',
    );
}

# Start a session to handle successfully connected clients.
sub poe_accepted {
  Chargen::Connection->new($_[ARG0]);
}

# Upon error, log the error and stop the server.  Client sessions may
# still be running, and the process will continue until they
# gracefully exit.
sub poe_error {
  warn "Chargen::Server encountered $_[ARG0] error $_[ARG1]: $_[ARG2]\n";
  delete $_[HEAP]->{listener};
}

#==============================================================================
# This is a simple chargen service.

package Chargen::Connection;
use POE::Session;

# Create a new chargen session around a successfully accepted socket.
sub new {
  my ($package, $socket) = @_;
  POE::Session->create
    ( inline_states =>
      { _start          => \&poe_start,
        wheel_got_flush => \&poe_got_flush,
        wheel_got_input => \&poe_got_input,
        wheel_got_error => \&poe_got_error,
        wheel_throttle  => \&poe_throttle,
        wheel_resume    => \&poe_resume,
        write_chunk     => \&poe_write_chunk,
      },
      args => [ $socket ],
    );
  undef;
}

# The session was set up within POE::Kernel, so it's safe to begin
# working.  Wrap a ReadWrite wheel around the socket, set up some
# persistent variables, and begin writing chunks.
sub poe_start {
  $_[HEAP]->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $_[ARG0],
      Driver       => POE::Driver::SysRW->new(),
      Filter       => POE::Filter::Line->new(),

      InputEvent   => 'wheel_got_input',
      ErrorEvent   => 'wheel_got_error',

      HighMark     => 256,
      LowMark      => 128,
      HighEvent    => 'wheel_throttle',
      LowEvent     => 'wheel_resume',
    );

  $_[HEAP]->{okay_to_send} = 1;
  $_[HEAP]->{start_character} = 32;

  $_[KERNEL]->yield('write_chunk');
}

# The client sent us input.  Rather than leaving it on the socket,
# we've read it to ignore it.
sub poe_got_input {
  warn "Chargen session ", $_[SESSION]->ID, " is ignoring some input.\n";
}

# An error occurred.  Log it and stop this session.  If the parent
# hasn't stopped, then it will continue running.
sub poe_got_error {
  warn( "Chargen session ", $_[SESSION]->ID, " encountered ", $_[ARG0],
        " error $_[ARG1]: $_[ARG2]\n"
      );
  $_[HEAP]->{okay_to_send} = 0;
  delete $_[HEAP]->{wheel};
}

# Write a chunk of data to the client socket.
sub poe_write_chunk {

  # Sometimes a write-chunk event comes in that ought not.  This race
  # occurs because water-mark events are called synchronously, while
  # write-chunk events are posted asynchronously.  So it may not be
  # okay to write a chunk when we get a write-chunk event.

  return unless $_[HEAP]->{okay_to_send};

	# Enqueue chunks until ReadWrite->put() signals that its driver's
	# buffer has reached (or exceeded) its high-water mark.

	while (1) {

		# Create a chargen line.  Build a 72-column line of consecutive
		# characters, starting with whatever character code we have
		# stored.  Wrap characters beyond "~" around to " ".
		my $chargen_line =
			join( '',
						map { chr }
						($_[HEAP]->{start_character} .. ($_[HEAP]->{start_character}+71))
					);
		$chargen_line =~ tr[\x7F-\xDD][\x20-\x7E];

		# Increment the start character, wrapping \x7F to \x20.
		$_[HEAP]->{start_character} = 32
			if (++$_[HEAP]->{start_character} > 126);

		# Enqueue the line for output.  Stop enqueuing lines if the
		# buffer's high water mark is reached.
		last if $_[HEAP]->{wheel}->put($chargen_line);
	}

	warn "Chargen session ", $_[SESSION]->ID, " writes are paused.\n";
}

# Be impressive.  Log that the session has throttled, and set a flag
# so spurious write-chunk events are ignored.

sub poe_throttle {
  warn "Chargen session ", $_[SESSION]->ID, " is throttled.\n";
  $_[HEAP]->{okay_to_send} = 0;
}

# Be impressive, part two.  Log that the session has resumed sending,
# and clear the stop-writing flag.  Only bother doing this if there's
# still a handle; that way it doesn't keep looping around after an
# error or something.

sub poe_resume {
  if (exists $_[HEAP]->{wheel}) {
    warn "Chargen session ", $_[SESSION]->ID, " is resuming.\n";
    $_[HEAP]->{okay_to_send} = 1;
    $_[KERNEL]->yield('write_chunk');
  }
}

#==============================================================================
# Main loop.  Create the server, and run it until something stops it.

package main;

print( "*** If all goes well, a watermarked (self-throttling) chargen\n",
       "*** service will be listening on localhost port $chargen_port.\n",
       "*** Watch it perform flow control by connecting to it over a slow\n",
       "*** connection or with a client you can pause.  The server will\n",
       "*** throttle itself when its output buffer becomes too large, and\n",
       "*** it will resume output when the client receives enough data.\n",
     );
Chargen::Server->new;
$poe_kernel->run();

exit;
