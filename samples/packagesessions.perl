#!perl -w -I..
# $Id$

# This is a simple test of "package sessions".  These are similar to
# object sessions, but they work with packages instead of objects.  It
# is also a simpler test than sessions.perl.

use strict;
use POE;

#==============================================================================
# Counter is a package composed of event handler functions.  It is
# never instantiated as an object here.

package Counter;
use strict;
use POE;
                                        # stupid scope trick, part 1 of 3
$Counter::name = '';

#------------------------------------------------------------------------------
# This is a normal subroutine, not an object method.  It sets up the
# session's variables and sets the session in motion.

sub _start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
                                        # register a signal handler
  $kernel->sig('INT', 'sigint');
                                        # initialize the counter
  $heap->{'counter'} = 0;
                                        # stupid scope trick, part 2 of 3
  $heap->{'name'} = $Counter::name;
                                        # hello, world!
  print "Session $heap->{'name'} started.\n";
                                        # start things moving
  $kernel->post($session, 'increment');
}

#------------------------------------------------------------------------------
# This is a normal subroutine, not an object method.  It cleans up
# after receiving POE's standard _stop event.

sub _stop {
  my $heap = $_[HEAP];

  print "Session $heap->{'name'} stopped after $heap->{'counter'} loops.\n";
}

#------------------------------------------------------------------------------
# This is a normal subroutine, and not an object method.  It will be
# registered as a SIGINT handler so that the session can acknowledge
# the signal.

sub sigint {
  my ($heap, $from, $signal_name) = @_[HEAP, SENDER, ARG0];

  print "$heap->{'name'} caught SIG$signal_name from $from\n";
                                        # did not handle the signal
  return 0;
}

#------------------------------------------------------------------------------
# This is a normal subroutine, and not an object method.  It does most
# of the counting work.  It loops by posting events back to itself.
# The session exits when there is nothing left to do; this event
# handler causes that condition when it stops posting events.

sub increment {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  $heap->{'counter'}++;

  print "Session $heap->{'name'}, iteration $heap->{'counter'}.\n";

  if ($heap->{'counter'} < 5) {
    $kernel->post($session, 'increment');
  }
  else {
    # no more events.  since there is nothing left to do, the session exits.
  }
}

#==============================================================================
# Create ten Counter sessions, all sharing the subs in package
# Counter.  In a way, POE's sessions provide a simple form of object
# instantiation.

package main;

foreach my $name (qw(one two three four five six seven eight nine ten)) {
                                        # stupid scope trick, part 3 of 3
  $Counter::name = $name;
                                        # create the session
  new POE::Session( 'Counter',
                    [ qw(_start _stop increment sigint) ]
                  );
}

$poe_kernel->run();

exit;

