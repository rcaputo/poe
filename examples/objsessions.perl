#!/usr/bin/perl -w

# This is another simple functionality test.  It tests sessions that
# are composed of objects (also called "object sessions").  It is
# simpler than sessions.perl in many ways.

use strict;
use lib '../lib';
use POE;

#==============================================================================
# Counter is an object that roughly approximates "child" sessions from
# the sessions.perl test.  It counts for a little while, then stops.

package Counter;
use strict;
use POE::Session;

#------------------------------------------------------------------------------
# This is a normal Perl object method.  It creates a new Counter
# instance and returns a reference to it.  It's also possible for the
# object to wrap itself in a Session within the constructor.
# Self-wrapping objects are explored in other examples.

sub new {
  my ($type, $name) = @_;
  print "Session ${name}'s object created.\n";
  bless { 'name' => $name }, $type;
}

#------------------------------------------------------------------------------
# This is a normal Perl object method.  It destroys a Counter object,
# doing any late cleanup on the object.  This is different than the
# _stop event handler, which handles late cleanup on the object's
# Session.

sub DESTROY {
  my $self = shift;
  print "Session $self->{name}'s object destroyed.\n";
}

#------------------------------------------------------------------------------
# This method is an event handler.  It sets the session in motion
# after POE sends the standard _start event.

sub _start {
  my ($object, $session, $heap, $kernel) = @_[OBJECT, SESSION, HEAP, KERNEL];
                                        # register a signal handler
  $kernel->sig('INT', 'sigint');
                                        # initialize the counter
  $heap->{'counter'} = 0;
                                        # hello, world!
  print "Session $object->{'name'} started.\n";

  $kernel->post($session, 'increment');
}

#------------------------------------------------------------------------------
# This method is an event handler, too.  It cleans up after receiving
# POE's standard _stop event.

sub _stop {
  my ($object, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];

  print "Session $object->{'name'} stopped after $heap->{'counter'} loops.\n";
}

#------------------------------------------------------------------------------
# This method is an event handler.  It will be registered as a SIGINT
# handler so that the session can acknowledge the signal.

sub sigint {
  my ($object, $from, $signal_name) = @_[OBJECT, SENDER, ARG0];

  print "$object->{'name'} caught SIG$signal_name from $from\n";
                                        # did not handle the signal
  return 0;
}

#------------------------------------------------------------------------------
# This method is an event handler.  It does most of counting work.  It
# loops by posting events back to itself.  The session exits when
# there is nothing left to do; this event handler causes that
# condition when it stops posting events.

sub increment {
  my ($object, $kernel, $session, $heap) = @_[OBJECT, KERNEL, SESSION, HEAP];

  $heap->{'counter'}++;

  if ($heap->{counter} % 2) {
    $kernel->state('runtime_state', $object);
  }
  else {
    $kernel->state('runtime_state');
  }

  print "Session $object->{'name'}, iteration $heap->{'counter'}.\n";

  if ($heap->{'counter'} < 5) {
    $kernel->post($session, 'increment');
    $kernel->yield('runtime_state', $heap->{counter});
  }
  else {
    # no more events.  since there is nothing left to do, the session exits.
  }
}

#------------------------------------------------------------------------------
# This state is added on every even count.  It's removed on every odd
# one.  Every count posts an event here.

sub runtime_state {
  my ($self, $iteration) = @_[OBJECT, ARG0];
  print( 'Session ', $self->{name},
         ' received a runtime_state event during iteration ',
         $iteration, "\n"
       );
}

#==============================================================================
# Create ten Counter objects, and wrap them in sessions.

package main;

foreach my $name (qw(one two three four five six seven eight nine ten)) {
  POE::Session->create(
    object_states => [
      Counter->new($name) => [ qw(_start _stop increment sigint) ]
    ],
  );
}

$poe_kernel->run();

exit;
