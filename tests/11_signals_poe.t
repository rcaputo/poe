#!/usr/bin/perl -w
# $Id$

# Tests various signals using POE's stock signal handlers.  These are
# plain Perl signals, so mileage may vary.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(2);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

my $fork_count = 8;

# Use Time::HiRes, if it's available.  This will get us super accurate
# sleep times so all the child processes wake up close together.  The
# idea is to have CHLD signals overlap.

eval {
  require Time::HiRes;
  import Time::HiRes qw(time sleep);
};

# Set up a signal catching session.  This test uses plain fork(2) and
# POE's $SIG{CHLD} handler.

my $delay_per_child = time() - $^T;
$delay_per_child = 5 if $delay_per_child < 5;
warn "delaying $delay_per_child per child";

POE::Session->create
  ( inline_states =>
    { _start =>
      sub {
        $_[HEAP]->{forked} = $_[HEAP]->{reaped} = 0;
        $_[KERNEL]->sig( CHLD => 'catch_sigchld' );

        my $wake_time = time() + ($delay_per_child * $fork_count);

        # Fork some child processes, all to exit at the same time.
        for (my $child = 0; $child < $fork_count; $child++) {
          my $child_pid = fork;

          if (defined $child_pid) {
            if ($child_pid) {
              $_[HEAP]->{forked}++;
            }
            else {
              sleep $wake_time - time();
              exit;
            }
          }
          else {
            warn "fork error: $!";
          }
        }

        if ($_[HEAP]->{forked} == $fork_count) {
          print "ok 1\n";
        }
        else {
          print "not ok 1 # forked $_[HEAP]->{forked} out of $fork_count\n";
        }

        $_[KERNEL]->delay( time_is_up => ($delay_per_child * $fork_count * 2) );
      },

      _stop =>
      sub {
        my $heap = $_[HEAP];
        if ($heap->{reaped} == $fork_count) {
          print "ok 2\n";
        }
        else {
          print "not ok 2 # reaped $heap->{reaped} out of $fork_count\n";
        }
      },

      catch_sigchld =>
      sub {
        $_[HEAP]->{reaped}++;
      },

      time_is_up =>
      sub {
        # do nothing, really
      },
    },
  );

# Run the tests.

$poe_kernel->run();

exit;
