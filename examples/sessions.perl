#!/usr/bin/perl -w

# This is the first test program written for POE.  It originally was
# written to test POE's ability to dispatch events to inline sessions
# (which was the only kind of sessions at the time).  It was later
# amended to test directly calling event handlers, delayed garbage
# collection, and some other things that new developers probably don't
# need to know. :)

use strict;
use lib '../lib';

# use POE always includes POE::Kernel and POE::Session, since they are
# the fundamental POE classes and universally used.  POE::Kernel
# exports the $kernel global, a reference to the process' Kernel
# instance.  POE::Session exports a number of constants for event
# handler parameter offsets.  Some of the offsets are KERNEL, HEAP,
# SESSION, and ARG0-ARG9.

use POE;
                                        # stupid scope trick, part 1 of 3 parts
my $session_name;

#==============================================================================
# This section defines the event handler (or state) subs for the
# sessions that this program calls "child" sessions.  Each sub does
# just one thing, possibly passing execution to other event handlers
# through one of the supported event-passing mechanisms.

#------------------------------------------------------------------------------
# Newly created sessions are not ready to run until the kernel
# registers them in its internal data structures.  The kernel sends
# every new session a _start event to tell them when they may begin.

sub child_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
                                        # stupid scope trick, part 2 of 3 parts
  $heap->{'name'} = $session_name;
  $kernel->sig('INT', 'sigint');

  my $sid = $session->ID();
  print "Session $heap->{'name'} (SID $sid) started.\n";
  return "i am $heap->{'name'} (SID $sid)";
}

#------------------------------------------------------------------------------
# Every session receives a _stop event just prior to being removed
# from memory.  This allows sessions to perform last-minute cleanup.

sub child_stop {
  my ($session, $heap) = @_[SESSION, HEAP];
  my $sid = $session->ID();
  print "Session $heap->{'name'} (SID $sid) stopped.\n";
}

#------------------------------------------------------------------------------
# This sub handles a developer-supplied event.  It accepts a name and
# a count, increments the count, and displays some information.  If
# the count is small enough, it feeds back on itself by posting
# another "increment" message.

sub child_increment {
  my ($kernel, $session, $name, $count) =
    @_[KERNEL, SESSION, ARG0, ARG1];

  $count++;

  if ($count % 2) {
    $kernel->state('runtime_state', \&child_runtime_state);
  }
  else {
    $kernel->state('runtime_state');
  }

  my $sid = $session->ID();
  print "Session $name (SID $sid), iteration $count...\n";

  my $ret = $kernel->call($session, 'display_one', $name, $count);
  print "\t(display one returns: $ret)\n";

  $ret = $kernel->call($session, 'display_two', $name, $count);
  print "\t(display two returns: $ret)\n";

  if ($count < 5) {
    $kernel->post($session, 'increment', $name, $count);
    $kernel->yield('runtime_state', $name, $count);
  }
}

#------------------------------------------------------------------------------
# This state is added on every even count.  It's removed on every odd
# one.  Every count posts an event here.

sub child_runtime_state {
  my ($name, $iteration) = @_[ARG0, ARG1];
  print( "Session $name received a runtime_state event ",
         "during iteration $iteration\n"
       );
}

#------------------------------------------------------------------------------
# This sub handles a developer-supplied event.  It is called (not
# posted) immediately by the "increment" event handler.  It displays
# some information about its parameters, and returns a value.  It is
# included to test that $kernel->call() works properly.

sub child_display_one {
  my ($name, $count) = @_[ARG0, ARG1];
  print "\t(display one, $name, iteration $count)\n";
  return $count * 2;
}

#------------------------------------------------------------------------------
# This sub handles a developer-supplied event.  It is called (not
# posted) immediately by the "increment" event handler.  It displays
# some information about its parameters, and returns a value.  It is
# included to test that $kernel->call() works properly.

sub child_display_two {
  my ($name, $count) = @_[ARG0, ARG1];
  print "\t(display two, $name, iteration $count)\n";
  return $count * 3;
}

#------------------------------------------------------------------------------
# This event handler is a helper for child sessions.  It returns the
# session's name.  Parent sessions should call it directly.

sub child_fetch_name {
  $_[HEAP]->{'name'};
}

#==============================================================================
# This section defines the event handler (or state) subs for the
# sessions that this program calls "parent" sessions.  Each sub does
# just one thing, possibly passing execution to other event handlers
# through one of the supported event-passing mechanisms.

#------------------------------------------------------------------------------
# Newly created sessions are not ready to run until the kernel
# registers them in its internal data structures.  The kernel sends
# every new session a _start event to tell them when they may begin.

sub main_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # start ten child sessions
  foreach my $name (qw(one two three four five six seven eight nine ten)) {
                                        # stupid scope trick, part 3 of 3 parts
    $session_name = $name;
    my $session = POE::Session->create(
      inline_states => {
        _start      => \&child_start,
        _stop       => \&child_stop,
        increment   => \&child_increment,
        display_one => \&child_display_one,
        display_two => \&child_display_two,
        fetch_name  => \&child_fetch_name,
      }
    );

    # Normally, sessions are stopped if they have nothing to do.  The
    # only exception to this rule is newly created sessions.  Their
    # garbage collection is delayed slightly, so that parent sessions
    # may send them "bootstrap" events.  The following post() call is
    # such a bootstrap event.

    $kernel->post($session, 'increment', $name, 0);
  }
}

#------------------------------------------------------------------------------
# POE's _stop events are not mandatory.

sub main_stop {
  print "*** Main session stopped.\n";
}

#------------------------------------------------------------------------------
# POE sends a _child event whenever a child session is about to
# receive a _stop event (or has received a _start event).  The
# direction argument is either 'gain', 'lose' or 'create', to signify
# whether the child is being given to, taken away from, or created by
# the session (respectively).

sub main_child {
  my ($kernel, $session, $direction, $child, $return) =
    @_[KERNEL, SESSION, ARG0, ARG1, ARG2];

  my $sid = $session->ID();
  print( "*** Main session (SID $sid) ${direction}s child ",
         $kernel->call($child, 'fetch_name'),
         (($direction eq 'create') ? " (child returns: $return)" : ''),
         "\n"
       );
}

#==============================================================================
# Start the main (parent) session, and begin processing events.
# Kernel::run() will continue until there is nothing left to do.

POE::Session->create(
  inline_states => {
    _start => \&main_start,
    _stop  => \&main_stop,
    _child => \&main_child,
  }
);

$poe_kernel->run();

exit;
