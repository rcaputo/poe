#!/usr/bin/perl -w
# $Id$

# This program tests the high and low watermarks.  It merges the
# wheels from wheels.perl and the chargen service from selects.perl to
# create a wheel-based chargen service.

use strict;
use lib '..';
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);

my $chargen_port = 32019;

#==============================================================================
# This is a simple TCP server.  It answers connections and passes them
# to new chargen service sessions.

package Chargen::Server;
use POE::Session;

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

sub poe_start {
  $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new
    ( SuccessState => 'accepted',
      FailureState => 'error',
      BindPort     => $chargen_port,
    );
}

sub poe_accepted {
  Chargen::Connection->new($_[ARG0]);
}

sub poe_error {
  warn "Chargen::Server encountered $_[ARG0] error $_[ARG1]: $_[ARG2]\n";
  delete $_[HEAP]->{listener};
}

#==============================================================================
# This is a simple chargen service.

package Chargen::Connection;
use POE::Session;

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

sub poe_start {
  $_[HEAP]->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $_[ARG0],
      Driver       => POE::Driver::SysRW->new(),
      Filter       => POE::Filter::Line->new(),

      InputState   => 'wheel_got_input',
      ErrorState   => 'wheel_got_error',

      HighMark     => 256,
      LowMark      => 128,
      HighState    => 'wheel_throttle',
      LowState     => 'wheel_resume',
    );

  $_[HEAP]->{okay_to_send} = 1;
  $_[HEAP]->{start_character} = 32;

  $_[KERNEL]->yield('write_chunk');
}

sub poe_got_input {
  warn "Chargen session ", $_[SESSION]->ID, " is ignoring some input.\n";
}

sub poe_got_error {
  warn( "Chargen session ", $_[SESSION]->ID, " encountered ", $_[ARG0],
        " error $_[ARG1]: $_[ARG2]\n"
      );
  delete $_[HEAP]->{wheel};
}

sub poe_write_chunk {

  if (exists($_[HEAP]->{wheel}) and $_[HEAP]->{okay_to_send}) {

    # Create a chargen line.
    my $chargen_line =
      join( '',
            map { chr }
            ( $_[HEAP]->{start_character} .. ($_[HEAP]->{start_character}+71) )
          );
    $chargen_line =~ tr[\x7F-\xDD][\x20-\x7E];

    # Increment the next line's start character.
    $_[HEAP]->{start_character} = 32 if (++$_[HEAP]->{start_character} > 126);

    # Write the line.
    $_[HEAP]->{wheel}->put($chargen_line);

    # Go around again!
    $_[KERNEL]->yield('write_chunk');
  }

}

sub poe_throttle {
  warn "Chargen session ", $_[SESSION]->ID, " is throttled.\n";
  $_[HEAP]->{okay_to_send} = 0;
}

sub poe_resume {
  warn "Chargen session ", $_[SESSION]->ID, " is resuming.\n";
  $_[HEAP]->{okay_to_send} = 1;
  $_[KERNEL]->yield('write_chunk');
}

#==============================================================================
# Main loop.  Create the server, and run it until something stops it.

package main;

new Chargen::Server;
$poe_kernel->run();

exit;
