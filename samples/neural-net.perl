#!/usr/bin/perl -w

# Mini tutorial for writing neural networks atop POE.

# First we get some of the preliminary bits out of the way.  Turn on
# stricture (and warnings, above), and use POE.  POE pulls in
# POE::Kernel and POE::Session for you, instantiating the process'
# kernel at the same time, and that's all we really need to fake
# concurrency.

use strict;
use lib '..';
use POE;

# Now to define one sort of neuron.  Every session's gotta start
# somehow, and so the predefined _start state exists.

sub neuron_start {
  # Every session receives a number of standard parameters, followed
  # by whatever parameters are included with the event.  $_[KERNEL] is
  # a reference to the process' global POE::Kernel.  $_[SESSION] is a
  # reference to the current session.  $_[HEAP] is this session's
  # private storage space.  It's separate from every other session's
  # heap.  $_[ARG0] is the first argument passed in
  # POE::Session->create's args parameter.

  my ( $kernel, $session, $heap,
       $neuron_name, $threshhold, $low_fire, $high_fire
     ) = @_[KERNEL, SESSION, HEAP, ARG0..ARG3];

  # Save things this neuron needs to know about itself.
  $heap->{name}       = $neuron_name;
  $heap->{threshhold} = $threshhold;
  $heap->{low_fire}   = $low_fire;
  $heap->{high_fire}  = $high_fire;
  $heap->{value}      = 0;

  # Register the neuron's name, so POE knows which one you mean when
  # you use the name later.
  $kernel->alias_set( $neuron_name );

  # Be noisy for the sake of science.
  print "Neuron '$heap->{name}' started.\n";
}

# Now we need a way to stimulate the neuron.  This state defines how a
# neuron receives and reacts to a stimulus.

sub neuron_stimulated {
  my ($kernel, $session, $heap, $value) = @_[KERNEL, SESSION, HEAP, ARG0];

  # Add the stimulus to the neuron's accumulator, and be noisy.
  $heap->{value} += $value;
  print "Neuron $heap->{name} received $value and now has $heap->{value}.\n";

  # If this stimulus pushes the neuron over a threshhold, then fire a
  # stimulus to the "high" neighbor neuron.  If there's no such
  # neuron, then move on to "low" bit.
  if ($heap->{value} >= $heap->{threshhold}) {
    if (length $heap->{high_fire}) {
      $kernel->post( $heap->{high_fire}, stimulate => 10 );
      print( "Neuron $heap->{name} reached its threshhold and fired to ",
             "$heap->{high_fire}.\n"
           );
    }
    else {
      print( "Neuron $heap->{name} reached its threshhold and has ",
             "nothing to do.\n"
           );
    }

    # Oh, and reset the accumulator so this neuron never gets stuck in
    # a "high" position.
    $heap->{value} = 0;
  }

  # Always fire a stimulus to the low-threshhold neuron, but do this
  # after a brief, random delay.
  if (length $heap->{low_fire}) {

    # The delay() method supersedes previous delays for the same state
    # (respond_later here), so we can't enqueue several of them that
    # way.  delay_add(), on the other hand, adds additional delays
    # which don't clear previous ones.  We use it to allow several
    # respond_later delays to pile up.
    $kernel->delay_add( respond_later => rand(5) );
  }
}

# Respond after a delay.  The delay is done, and we can now fire the
# low-threshhold event.

sub neuron_delayed_response {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $kernel->post($heap->{low_fire}, stimulate => 10 );
  print "Neuron $heap->{name} has fired a stimulus to $heap->{low_fire}.\n";
}

# Define a small neural net.  I have no idea what I'm doing, so this
# probably doesn't make much sense.  Each neuron contains four fields:
# the neuron's name, its threshhold value, the neuron to stimulate
# when its accumulator is below a threshhold (always), and the one to
# stimulate when the threshhold is reached.

my @neural_net =
  ( [ 'one',   10, 'one',   'two'   ],
    [ 'two',   20, 'three', 'four'  ],
    [ 'three', 30, 'five',  'six'   ],
    [ 'four',  50, 'seven', 'eight' ],
    [ 'five', 100, 'nine',  'ten'   ],
    [ 'six',   70, 'seven', 'eight' ],
    [ 'seven', 80, 'nine',  'ten'   ],
    [ 'eight', 40, 'nine',  'ten'   ],
    [ 'nine',  60, '',      'ten'   ],
    [ 'ten',   90, '',      ''      ],
  );

# Spawn a session for each neuron.  Each neuron is given its
# parameters, and it runs on its own from now on.  You can make larger
# networks by expanding @neural_net; this loop will instantiate as
# many as can fit in memory.
foreach (@neural_net) {
  my ($name, $threshhold, $low, $high) = @$_;

  # Sessions act sort of like event-driven threads.  This spawns new
  # ones with the bits of code that they'll run.
  POE::Session->create
    ( inline_states =>
      { _start        => \&neuron_start,
        stimulate     => \&neuron_stimulated,
        respond_later => \&neuron_delayed_response,
      },
      # ARG0..ARG3 for _start:
      args => [ $name, $threshhold, $low, $high ],
    );
}

# Prod the network into life by giving it an initial stimulus.
# $poe_kernel is provided for times when you can't get to $_[KERNEL],
# such as when you're not inside any state (like now).
$poe_kernel->post( one => stimulate => 10 );

# Finally, start POE's main loop rolling.  It will continue to run
# until the network achieves virtual braindeath.  That is, until all
# the neurons stop throbbing.  That'll only happen when each neuron
# has fired its last stimulus.  Or when someone presses ^C;
$poe_kernel->run();

exit;
