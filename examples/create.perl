#!/usr/bin/perl -w

# This is a version of sessions.perl that uses the &Session::create
# constructor.

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
  my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # stupid scope trick, part 2 of 3 parts
  $heap->{'name'} = $session_name;
  $kernel->sig('INT', 'sigint');
  print "Session $heap->{'name'} started.\n";

  return "i am $heap->{'name'}";
}

#------------------------------------------------------------------------------
# Every session receives a _stop event just prior to being removed
# from memory.  This allows sessions to perform last-minute cleanup.

sub child_stop {
  my $heap = $_[HEAP];
  print "Session ", $heap->{'name'}, " stopped.\n";
}

#------------------------------------------------------------------------------
# This sub handles a developer-supplied event.  It accepts a name and
# a count, increments the count, and displays some information.  If
# the count is small enough, it feeds back on itself by posting
# another "increment" message.

sub child_increment {
  my ($kernel, $me, $name, $count) =
    @_[KERNEL, SESSION, ARG0, ARG1];

  $count++;

  print "Session $name, iteration $count...\n";

  my $ret = $kernel->call($me, 'display_one', $name, $count);
  print "\t(display one returns: $ret)\n";

  $ret = $kernel->call($me, 'display_two', $name, $count);
  print "\t(display two returns: $ret)\n";

  if ($count < 5) {
    $kernel->post($me, 'increment', $name, $count);
  }
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
# Define an object for object sessions.

package Counter;

sub new {
  my $type = shift;
  my $self = bless [], $type;
  $self;
}

sub _start      { goto &main::child_start       }
sub _stop       { goto &main::child_stop        }
sub increment   { goto &main::child_increment   }
sub display_one { goto &main::child_display_one }
sub display_two { goto &main::child_display_two }
sub fetch_name  { goto &main::child_fetch_name  }

#==============================================================================
# This section defines the event handler (or state) subs for the
# sessions that this program calls "parent" sessions.  Each sub does
# just one thing, possibly passing execution to other event handlers
# through one of the supported event-passing mechanisms.

package main;

#------------------------------------------------------------------------------
# Newly created sessions are not ready to run until the kernel
# registers them in its internal data structures.  The kernel sends
# every new session a _start event to tell them when they may begin.

sub main_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # start ten child sessions
  foreach my $name (qw(one two three four five)) {
                                        # stupid scope trick, part 3 of 3 parts
    $session_name = $name;
    my $session = POE::Session->create
      ( inline_states =>
        { _start      => \&child_start,
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

  foreach my $name (qw(six seven eight nine ten)) {
    # stupid scope trick, part 4 of 3 parts (that just shows you how
    # stupid it is)
    $session_name = $name;
    my $session = POE::Session->create
      ( object_states =>
        [ new Counter, [ '_start', '_stop',
                         'increment', 'display_one', 'display_two',
                         'fetch_name',
                       ],
        ],
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
  my ($kernel, $me, $direction, $child, $return) =
    @_[KERNEL, SESSION, ARG0, ARG1, ARG2];

  print( "*** Main session ${direction}s child ",
         $kernel->call($child, 'fetch_name'),
         (($direction eq 'create') ? " (child returns: $return)" : ''),
         "\n"
       );
}

#==============================================================================
# Start the main (parent) session, and begin processing events.
# Kernel::run() will continue until there is nothing left to do.

create POE::Session
  ( inline_states => 
    { _start => \&main_start,
      _stop  => \&main_stop,
      _child => \&main_child,
    }
  );

$poe_kernel->run();

exit;
