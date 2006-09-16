#!/usr/bin/perl -w
# $Id$

# Tests various signals using POE's stock signal handlers.  These are
# plain Perl signals, so mileage may vary.

use strict;
use lib qw(./mylib ../mylib);

use Test::More;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

# This is the number of processes to fork.  Increase this number if
# your system can handle the resource use.  Also try increasing it if
# you suspect a problem with POE's SIGCHLD handling.  Be warned
# though: setting this too high can cause timing problems and test
# failures on some systems.

my $fork_count;

BEGIN {
  # We can't "plan skip_all" because that calls exit().  And Tk will
  # croak if you call BEGIN { exit() }.  And that croak will cause
  # this test to FAIL instead of skip.

  my $error;
  if ($^O eq "MSWin32") {
    $error = "$^O does not support signals";
  }
  elsif ($^O eq "MacOS") {
    $error = "$^O does not support fork";
  }

  if ($error) {
    print "1..0 # Skip $error\n";
    CORE::exit();
  }

  $fork_count = 8;
  plan tests => $fork_count + 7;
}

BEGIN { use_ok("POE") }

# Set up a second session that watches for child signals.  This is ot
# test whether a session with only sig_child() stays alive because of
# the signals.

POE::Session->create(
  inline_states => {
    _start => sub { $_[KERNEL]->alias_set("catcher") },
    catch  => sub {
      my ($kernel, $heap, $pid) = @_[KERNEL, HEAP, ARG0];
			$kernel->sig(CHLD => "got_sigchld");
      $kernel->sig_child($pid, "got_chld");
      $heap->{children}{$pid} = 1;
      $heap->{watched}++;
    },
    remove_alias => sub { $_[KERNEL]->alias_remove("catcher") },
    got_chld => sub {
      my ($heap, $pid) = @_[HEAP, ARG1];
      ok(delete($heap->{children}{$pid}), "caught SIGCHLD for watched pid $pid");
      $heap->{caught}++;
    },
		got_sigchld => sub {
			$_[HEAP]->{caught_sigchld}++;
		},
    _stop => sub {
      my $heap = $_[HEAP];

      ok(
        $heap->{watched} == $heap->{caught},
        "expected $heap->{watched} reaped children, got $heap->{caught}"
      );

			ok(
				$heap->{watched} == $heap->{caught_sigchld},
        "expected $heap->{watched} sig(CHLD), got $heap->{caught_sigchld}"
			);

      ok(!keys(%{$heap->{children}}), "all reaped children were watched");
    },
  },
);

# Set up a signal catching session.  This test uses plain fork(2) and
# POE's $SIG{CHLD} handler.

POE::Session->create(
  inline_states => {
    _start => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];

      # Clear the status counters, and catch SIGCHLD.

      $heap->{forked} = $heap->{reaped} = 0;

      # Fork some child processes, all to exit at the same time.

      my $fork_start_time = time();

      for (my $child = 0; $child < $fork_count; $child++) {
        my $child_pid = fork;

        if (defined $child_pid) {
          if ($child_pid) {
            # Parent side keeps track of child IDs.
            $heap->{forked}++;
            $heap->{children}{$child_pid} = 1;
            $kernel->sig_child($child_pid, "catch_sigchld");
            $kernel->post(catcher => catch => $child_pid);
          }
          else {
            # Child side sleeps. With the fishes.
            $SIG{INT} = 'DEFAULT';
            sleep 3600;
            exit;
          }
        }
        else {
          die "fork error: $!";
        }
      }


      ok(
        $heap->{forked} == $fork_count,
        "forked $heap->{forked} processes (out of $fork_count)"
      );

      # Wait a factor of the fork time for things to settle down.
      # This prevents false negatives on slower systems.

      my $fork_delay = time() - $fork_start_time;

      if ($fork_delay < 2) {
        $fork_delay = 2;
      }
      elsif ($fork_delay < 5) {
        $fork_delay = 5;
      }
      else {
        $fork_delay = 10;
      }

      $kernel->delay( forking_time_is_up => $fork_delay );
      diag("Waiting $fork_delay seconds for child processes to settle.");
    },

    _stop => sub {
      my $heap = $_[HEAP];

      # Everything is done.  See whether it succeeded.
      ok(
        $heap->{reaped} == $heap->{forked},
        "reaped $heap->{reaped} processes (out of $heap->{forked})"
      );
    },

    catch_sigchld => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];

      # Count the child reap.
      $heap->{reaped}++;

      # Refresh the fork timeout.
      $kernel->delay(
        reaping_time_is_up => 2 * ($heap->{forked} - $heap->{reaped} + 1)
      );
    },

    forking_time_is_up => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];

      # Forking time is over.  We kill all the child processes as
      # immediately as possible.

      my $kill_count = kill INT => keys(%{$heap->{children}});
      ok(
        $kill_count == $heap->{forked},
        "killed $kill_count processes (out of $heap->{forked})"
      );

      # Start the reap timer.  This will tell us how long to wait
      # between CHLD signals.

      $heap->{reap_start} = time();

      # Wait a factor of the number of child processes, plus one, for
      # reaped children.  The extra time is to ensure we don't reap
      # more processes than we started with.

      $kernel->delay(
        reaping_time_is_up => 2 * ($heap->{forked} - $heap->{reaped} + 1)
      );
    },

    # Do nothing here.  The timer exists just to keep the session
    # alive.  Once it's dispatched, the session can exit.
    reaping_time_is_up => sub { },
  },
);

# Run the tests.

POE::Kernel->run();

1;
