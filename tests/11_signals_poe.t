#!/usr/bin/perl -w
# $Id$

# Tests various signals using POE's stock signal handlers.  These are
# plain Perl signals, so mileage may vary.

use strict;
use lib qw(./mylib ../mylib .. .);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN {
  test_setup(0, "$^O does not support signals.") if $^O eq "MSWin32";
  test_setup(0, "$^O does not support fork.") if $^O eq "MacOS";
};

test_setup(4);

use POE;

# This is the number of children to fork.  Increase this number if
# your system can handle the resource use.  Also try increasing it if
# you suspect a problem with POE's SIGCHLD handling.  Be warned
# though: setting this too high can cause timing problems and test
# failures on some systems.
my $fork_count = 8;

# Let the user know what in heck is going on.
my $start_time = time();
warn( "\n",
      "***\n",
      "*** This test tries to compensate for slow machines.  It times its\n",
      "*** first test and uses that as its timeout for subsequent tests.\n",
      "*** This test may take a while on slow or resource-starved machines.\n",
      "*** It may even fail if it incorrectly estimates its timeouts.\n",
      "***\n"
    );

# Set up a signal catching session.  This test uses plain fork(2) and
# POE's $SIG{CHLD} handler.

POE::Session->create
  ( inline_states =>
    { _start =>
      sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Clear the status counters, and catch SIGCHLD.
        $heap->{forked} = $heap->{reaped} = 0;
        $kernel->sig( CHLD => 'catch_sigchld' );

        # Time how long it takes to fork the children.
	my $fork_start_time = time();

        # Fork some child processes, all to exit at the same time.
        for (my $child = 0; $child < $fork_count; $child++) {
          my $child_pid = fork;

          if (defined $child_pid) {
            if ($child_pid) {
              # Parent side keeps track of child IDs.
              $heap->{forked}++;
              $heap->{children}->{$child_pid} = 1;
            }
            else {
              # Child side sleeps. With the fishes.
              $SIG{INT} = 'DEFAULT';
              sleep 3600;
              exit;
            }
          }
          else {
            warn "fork error: $!";
          }
        }

        if ($heap->{forked} == $fork_count) {
          print "ok 1\n";
        }
        else {
          print "not ok 1 # forked $heap->{forked} out of $fork_count\n";
        }

        # Use the time it took to fork children as a base for the
        # other tests' timeouts.
        my $elapsed = time() - $fork_start_time;
        $heap->{fork_time} = $elapsed * 2;
        $heap->{fork_time} = 10 if $heap->{fork_time} < 10;

        warn( "\n",
              "***\n",
              "*** Seconds to fork $heap->{forked} children: $elapsed\n",
              "*** Seconds to wait for system to settle: $heap->{fork_time}\n",
              "***\n"
            );

        # Wait a duplicate of the fork time for things to settle
        # and/or swap out. :)
        $kernel->delay( forking_time_is_up => $heap->{fork_time} );
      },

      _stop =>
      sub {
        my $heap = $_[HEAP];

        # Everything is done.  See whether it succeeded.
        if ($heap->{reaped} == $fork_count) {
          print "ok 3 # after ", time() - $start_time, " seconds\n";
        }
        else {
          print "not ok 3 # reaped $heap->{reaped} out of $fork_count\n";
        }
      },

      catch_sigchld =>
      sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Count the child reap.
        $heap->{reaped}++;

        unless (defined $heap->{reap_wait}) {
          my $elapsed = time() - $heap->{reap_start};
          $heap->{reap_wait} = $elapsed * 2;
          $heap->{reap_wait} = 5 if $heap->{reap_wait} < 5;

          warn( "\n",
                "***\n",
                "*** Seconds between signal and first reap: $elapsed\n",
                "*** Seconds to wait for other reaps: $heap->{reap_wait}\n",
                "*** Seconds to wait after final reap: 5\n",
                "***\n"
              );
        }

        $heap->{reap_wait} = 5 if $heap->{reaped} == $heap->{forked};

        # Change the wait time based on the first reap.
        $kernel->delay( reaping_time_is_up => $heap->{reap_wait} );
      },

      forking_time_is_up =>
      sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Forking time is over.  We kill all the children as
        # immediately as possible.
        my $kill_count = kill INT => keys(%{$heap->{children}});
        print 'not ' unless $kill_count == $heap->{forked};
        print "ok 2\n";

        # Start the reap timer.  This will tell us how long to wait
        # between CHLD signals.
        $heap->{reap_start} = time();

        # Wait the fork time again, in the absence of any better delay.
        $kernel->delay( reaping_time_is_up => $heap->{fork_time} );
      },

      reaping_time_is_up =>
      sub {
        # Time to reap is up.  Do nothing here, which means the
        # session exits.
      },
    },
  );

# mstevens found a subtle incompatibility between nested sessions and
# SIGIDLE.  This should be fun to debug, but first I'll add the test
# case here.

sub spawn_server {
  POE::Session->new
    ( _start => sub {
        $_[KERNEL]->alias_set("server");
      },
      do_thing => sub {
        $_[KERNEL]->post($_[SENDER], thing_done => $_[ARG0]);
      },
      _child  => sub { 0 },
      _stop   => sub { 0 },
    );
}

POE::Session->new
  ( _start => sub {
      spawn_server();
      $_[KERNEL]->post(server => do_thing => 1);
    },
    thing_done => sub { 0 },
    _child  => sub { 0 },
    _stop   => sub { 0 },
  );

# Run the tests.

$poe_kernel->run();
print "ok 4\n";
exit;
