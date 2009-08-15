#!/usr/bin/perl -w -I..

# This is another of the earlier test programs.  It creates a single
# session whose job is to create more of itself.  There is a built-in
# limit of 200 sessions, after which they all politely stop.

# This program's main purpose in life is to test POE's parent/child
# relationships, signal propagation and garbage collection.

use strict;
use lib '../lib';

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;

#==============================================================================
# These subs implement the guts of a forkbomb session.  Its only
# mission in life is to spawn more of itself until it dies.

my $count = 0;                          # session counter for limiting runtime

#------------------------------------------------------------------------------
# This sub handles POE's standard _start event.  It initializes the
# session.

sub _start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # assign the next count to this session
  $heap->{'id'} = ++$count;
  printf "%4d has started.\n", $heap->{'id'};
                                        # register signal handlers
  $kernel->sig('INT', 'signal_handler');
  $kernel->sig('ZOMBIE', 'signal_handler');
                                        # start forking
  $kernel->yield('fork');
                                        # return something interesting
  return "i am $heap->{'id'}";
}

#------------------------------------------------------------------------------
# This sub handles POE's standard _stop event.  It acknowledges that
# the session is stopped.

sub _stop {
  printf "%4d has stopped.\n", $_[HEAP]->{'id'};
}

#------------------------------------------------------------------------------
# This sub handles POE's standard _child event.  It acknowledges that
# the session is gaining or losing a child session.

my %english = ( lose   => 'is losing',
                gain   => 'is gaining',
                create => 'has created'
              );

sub _child {
  my ($kernel, $heap, $direction, $child, $return) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

  printf( "%4d %s child %s%s\n",
          $heap->{'id'},
          $english{$direction},
          $kernel->call($child, 'fetch_id'),
          (($direction eq 'create') ? (" (child returned: $return)") : '')
        );
}

#------------------------------------------------------------------------------
# This sub handles POE's standard _parent event.  It acknowledges that
# the child session's parent is changing.

sub _parent {
  my ($kernel, $heap, $old_parent, $new_parent) = @_[KERNEL, HEAP, ARG0, ARG1];
  printf( "%4d parent is changing from %d to %d\n",
          $heap->{'id'},
          $kernel->call($old_parent, 'fetch_id'),
          $kernel->call($new_parent, 'fetch_id')
        );
}

#------------------------------------------------------------------------------
# This sub acknowledges receipt of signals.  It's registered as the
# handler for SIGINT and SIGZOMBIE.  It returns 0 to tell the kernel
# that the signals were not handled.  This causes the kernel to stop
# the session for certain "terminal" signals (such as SIGINT).

sub signal_handler {
  my ($heap, $signal_name) = @_[HEAP, ARG0];
  printf( "%4d has received SIG%s\n", $heap->{'id'}, $signal_name);
                                        # tell Kernel that this wasn't handled
  return 0;
}

#------------------------------------------------------------------------------
# This is the main part of the test.  This state uses the yield()
# function to loop until certain conditions are met.

my $max_sessions = 200;
my $half_sessions = int($max_sessions / 2);

sub fork {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Only consider continuing if the maximum number of sessions has not
  # yet been reached.

  if ($count < $max_sessions) {
                                        # flip a coin; heads == spawn
    if (rand() < 0.5) {
      printf "%4d is starting a new child...\n", $heap->{'id'};
      &create_new_forkbomber();
    }
                                        # tails == don't spawn
    else {
      printf "%4d is just spinning its wheels this time...\n", $heap->{'id'};
    }

    # Randomly decide to die (or not) if half the sessions have been
    # reached.

    if (($count < $half_sessions) || (rand() < 0.05)) {
      $kernel->yield('fork');
    }
    else {
      printf "%4d has decided to die.  Bye!\n", $heap->{'id'};

      # NOTE: Child sessions will keep a parent session alive.
      # Because of this, the program forces a stop by sending itself a
      # _stop event.  This normally isn't necessary.

      # NOTE: The main session (#1) is allowed to linger.  This
      # prevents strange things from happening when it exits
      # prematurely.

      if ($heap->{'id'} != 1) {
        $kernel->yield('_stop');
      }
    }
  }
  else {
    printf "%4d notes that the session limit is met.  Bye!\n", $heap->{'id'};

    # Please see the two NOTEs above.

    if ($heap->{'id'} != 1) {
      $kernel->yield('_stop');
    }
  }
}

#------------------------------------------------------------------------------
# This is a helper event handler.  It is called directly by parents
# and children to help identify the sessions being given or taken
# away.  It is just a public interface to the session's numeric ID.

sub fetch_id {
  return $_[HEAP]->{'id'};
}

#==============================================================================
# This is a helper function that creates a new forkbomber session.

sub create_new_forkbomber {
  POE::Session->create(
    inline_states => {
      '_start'         => \&_start,
      '_stop'          => \&_stop,
      '_child'         => \&_child,
      '_parent'        => \&_parent,
      'signal_handler' => \&signal_handler,
      'fork'           => \&fork,
      'fetch_id'       => \&fetch_id,
    }
  );
}

#==============================================================================
# Create the initial forkbomber session, and run the kernel.

&create_new_forkbomber();
$poe_kernel->run();

exit;
