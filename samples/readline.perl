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
        $_[HEAP]->{rl} = POE::Wheel::ReadLine->new( InputEvent => 'input' ),

        # Tell the user what to do.
        print( "\nEnter some text.\n",
               "Press C-c to exit, or type exit or quit or stop.\n",
               "Try some of the shell editing keys.\n\n",
             );

        # ReadLine ignores input until you tell it to get a line.
        # This effectively discards everything until get() is called.
        # The only parameter to get() is a prompt.
        $_[HEAP]->{rl}->get('Prompt: ');
      },

      # Got input, of some sort.  There are two types of input: If
      # ARG0 is defined, it's a line of input.  If it's undef, then
      # ARG1 contains an exception code ('interrupt' or 'abort' so
      # far).

      # The wheel disables new input once it's fired off an input
      # event.  If a program wants to continue receiving input, it
      # will need to call $wheel->get($prompt) again.  This makes the
      # behavior "one-shot", and it's a lot like Term::ReadLine.

      input => sub {
        my ($heap, $input, $exception) = @_[HEAP, ARG0, ARG1];

        # If it's real input, show it.  Exit if something interesting
        # was typed.
        if (defined $input) {
          print "\tGot: $input\x0D\x0A";
          return if $input eq 'exit' or $input eq 'quit' or $input eq 'stop';

          # Manage a history list.
          $heap->{rl}->addhistory($input);
        }

        # Otherwise it's an exception.  Show that, too, and exit if it
        # was an interrupt exception (C-c).
        else {
          print "  Exception: $exception\x0D\x0A";
          return if $exception eq 'interrupt';
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
