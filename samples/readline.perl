#!/usr/bin/perl -w
# $Id$

# Exercise POE::Wheel::ReadLine.  This really needs to be made into a
# non-interactive test for the `make test' suite.

use strict;
use lib '..';
use POE qw(Wheel::ReadLine);

# This quick, dirty inline session acts as an input loop.  It's
# smaller without the comments, but it's still pretty big compared to
# a plain input loop.  On the other hand, this one lets you do things
# in the background, between keystrokes.

POE::Session->create
  ( inline_states =>
    { _start => sub {

        # Start the ReadLine wheel here.  It has a very simple
        # constructor interface so far.
        $_[HEAP]->{rl} =
          POE::Wheel::ReadLine->new( InputEvent => 'input',
                                     PutMode    => 'immediate',
                                   );

        # Tell the user what to do.
        print( "\x0D\x0AEnter some text.\x0D\x0A",
               "Press C-c to exit, or type exit or quit or stop.\x0D\x0A",
               "Enter 'immediate' for an immediate wheel.\x0D\x0A",
               "Enter 'idle' for a two-second idle wheel.\x0D\x0A",
               "Enter 'after' for a hold-until-done wheel.\x0D\x0A",
               "Try some of the shell editing keys.\x0D\x0A\x0A",
             );

        # Start a timer loop to test put modes.
        $_[KERNEL]->delay( ding => 1 );

        # ReadLine ignores input until you tell it to get a line.
        # This effectively discards everything until get() is called.
        # The only parameter to get() is a prompt.
        $_[HEAP]->{rl}->get('Prompt: ');
      },

      # Display the time, or something, for to show that things occur
      # in the background.

      ding => sub {
        $_[HEAP]->{rl}->put( "\t" . scalar(localtime) );
        $_[KERNEL]->delay( ding => 1 );
      },

      # Got input, of some sort.  There are two types of input: If
      # ARG0 is defined, it's a line of input.  If it's undef, then
      # ARG1 contains an exception code ('interrupt' or 'cancel' so
      # far).

      # The wheel disables new input once it's fired off an input
      # event.  If a program wants to continue receiving input, it
      # will need to call $wheel->get($prompt) again.  This makes the
      # behavior "one-shot", and it's a lot like Term::ReadLine.

      input => sub {
        my ($kernel, $heap, $input, $exception) = @_[KERNEL, HEAP, ARG0, ARG1];

        # If it's real input, show it.  Exit if something interesting
        # was typed.
        if (defined $input) {
          print "\tGot: $input\x0D\x0A";

          if ($input =~ /^(exit|quit|stop)$/i) {
            $kernel->delay( 'ding' );
            return;
          }

          if ($input =~ /^(immediate|after|idle)$/) {
            delete $_[HEAP]->{rl};
            $_[HEAP]->{rl} =
              POE::Wheel::ReadLine->new( InputEvent => 'input',
                                         PutMode    => $input,
                                       );
          }

          # Manage a history list.
          $heap->{rl}->addhistory($input);
        }

        # Otherwise it's an exception.  Show that, too, and exit if it
        # was an interrupt exception (C-c).
        else {
          print "  Exception: $exception\x0D\x0A";
          if ($exception eq 'interrupt') {
            $kernel->delay( 'ding' );
            return;
          }
        }

        # Set up ReadLine to get another line.
        $heap->{rl}->get('Prompt: ');
      },
      _stop => sub {
        print "Stopped.\x0D\x0A";
      },
    },
  );

$poe_kernel->run();
exit 0;
