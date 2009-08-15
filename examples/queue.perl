#!/usr/bin/perl -w

# This is a simple job queue.

use strict;
use lib '../lib';

# sub POE::Kernel::TRACE_DEFAULT () { 1 }
# sub POE::Kernel::TRACE_GARBAGE () { 1 }
# sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;

### Configuration section.

# This is the maximum number of children permitted to be running at
# any moment.

my $child_max = 5;

### This is a "child" session.  The "parent" session will ensure that
### $child_max of these are running at any given time.

# The parent session needs to create children from two places.  Define
# a handy constructor rather than maintain duplicate copies of this
# POE::Session->create call.
sub create_a_child {
  POE::Session->create
    ( inline_states =>
      { _start  => \&child_start,
        _stop   => \&child_stop,
        wake_up => \&child_awaken,
      },
    );
}

# The child session has started.  Pretend to do something for a random
# amount of time.
sub child_start {
  my ($kernel, $session, $parent, $heap) = @_[KERNEL, SESSION, SENDER, HEAP];

  # Remember the parent.
  $heap->{parent} = $parent;

  # Take a random amount of time to "do" the "job".
  my $delay = int rand 10;
  warn "Child ", $session->ID, " will take $delay seconds to run.\n";
  $kernel->delay( wake_up => $delay );
}

# The child has finished whatever it was supposed to do.  Send the
# result of its labor back to the parent.
sub child_awaken {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # Fabricate the hypothetical job's result.
  my $result = int rand 100;
  warn "Child ", $session->ID, " is done doing something.  Result=$result\n";

  # Post the result back to the parent.  The child has nothing left to
  # do, and so it stops.
  $kernel->post($heap->{parent}, 'result', $session->ID, $result);
}

# The child has stopped.  Display a message to help illustrate what's
# going on.
sub child_stop {
  my $session = $_[SESSION];
  warn "Child ", $session->ID, " is stopped.\n";
}

### This is the "parent" session.  One of these will ensure that
### $child_max children are running beneath it.  It's possible to have
### several parent sessions; each will manage a separate pool of
### children.

# The parent session is starting.  Populate its pool with an initial
# group of child sessions.
sub parent_start {
  $_[HEAP]->{child_count} = 0;
  for (my $i=0; $i<$child_max; $i++) {
    &create_a_child;
  }
}

# The parent has either gained a new child or lost an existing one.
# If a new child is gained, track it.  If an existing child is lost,
# then spawn a replacement.
sub parent_child {
  my ($heap, $what, $child) = @_[HEAP, ARG0, ARG1];

  # This child is arriving, either by being created or by being
  # abandoned by some other session.  Count it as a child in our pool.
  if ($what eq 'create' or $what eq 'gain') {
    $heap->{child_count}++;
    warn( "Child ", $child->ID, " has appeared to parent ",
          $_[SESSION]->ID, " (", $heap->{child_count},
          " active children now).\n"
        );
  }

  # This child is departing.  Remove it from our pool count; if we
  # have fewer children than $child_max, then spawn a new one to take
  # the departing child's place.
  elsif ($what eq 'lose') {
    $heap->{child_count}--;
    warn( "Child ", $child->ID, " has left parent ",
          $_[SESSION]->ID, " (", $heap->{child_count},
          " active children now).\n"
        );
    if ($heap->{child_count} < $child_max) {
      &create_a_child;
    }
  }
}

# Receive a child session's result.
sub parent_result {
  my ($child, $result) = @_[ARG0, ARG1];
  warn "Parent received result from session $child: $result\n";
}

# Track when the parent leaves.
sub parent_stop {
  warn "Parent ", $_[SESSION]->ID, " stopped.\n";
}

### Main loop.  Start a parent session, which will, in turn, start its
### children.  Run until everything is done; in this case, until the
### user presses Ctrl+C.  Note: The children which are currently
### "working" will continue after Ctrl+C until they are "done".

POE::Session->create
  ( inline_states =>
    { _start => \&parent_start,
      _stop  => \&parent_stop,
      _child => \&parent_child,
      result => \&parent_result,
    }
  );

$poe_kernel->run();

exit;
