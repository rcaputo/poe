#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./mylib ../mylib ./lib ../lib ../../lib);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

sub BOGUS_SESSION () { 31415 }

test_setup(27);

# This subsystem is still very closely tied to POE::Kernel, so we
# can't call initialize ourselves.  TODO Separate it, if possible,
# enough to make this feasable.

my $event_id =
  $poe_kernel->_data_ev_enqueue(
    $poe_kernel,  # session
    $poe_kernel,  # source_session
    "event",      # event
    0x80000000,   # event type (hopefully unused)
    [],           # etc
    __FILE__,     # file
    __LINE__,     # line
    0,            # time (beginning thereof)
  );

# Event 1 is the kernel's signal poll timer.
# Event 2 is the kernel's performance poll timer.
ok_if(1, $event_id == 3);

# Kernel should have three events due.  A nonexistent session should
# have zero.

ok_if(2, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 3);
ok_if(3, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 3);
ok_if(4, $poe_kernel->_data_ev_get_count_from("nothing") == 0);
ok_if(5, $poe_kernel->_data_ev_get_count_to("nothing") == 0);

# Signal timer (x2), performance timer (x2), session, and from/to for
# the event we enqueued.  TODO - Why not 7?
ok_if(6, $poe_kernel->_data_ses_refcount($poe_kernel) == 6);

# Dequeue due events.  This should be just the one we enqueued because
# the other is scheduled for a second hence.
$poe_kernel->_data_ev_dispatch_due();

check_references($poe_kernel, 7);

# Test timer maintenance functions.  Add some alarms: Three with
# identical names, and one with another name.  Remember the ID of one
# of them, so we can remove it explicitly.  The other three should
# remain.  Remove them by name, and both the remaining ones with the
# same name should disappear.  The final alarm will be removed by
# clearing alarms for the session.

my @ids;
for (1..4) {
  my $timer_name = "timer";
  $timer_name = "other-timer" if $_ == 4;

  push(
    @ids,
    $poe_kernel->_data_ev_enqueue(
      $poe_kernel,           # session
      $poe_kernel,           # source_session
      $timer_name,           # event
      POE::Kernel::ET_ALARM, # event type
      [],                    # etc
      __FILE__,              # file
      __LINE__,              # line
      $_,                    # time
    )
  );
}

# The from and to counts should add up to the reference count.
check_references($poe_kernel, 9);

# Remove one of the alarms by its ID.  The reference count should be 8.
my ($time, $event) = $poe_kernel->_data_ev_clear_alarm_by_id(
  $poe_kernel, $ids[1]
);
ok_if(11, $time == 2);
ok_if(12, $event->[POE::Kernel::EV_NAME] eq "timer");

check_references($poe_kernel, 13);

# Remove an alarm by name, except that this is for a nonexistent
# session.
$poe_kernel->_data_ev_clear_alarm_by_name(BOGUS_SESSION, "timer");
check_references($poe_kernel, 15);

ok_if(17, $poe_kernel->_data_ev_get_count_from(BOGUS_SESSION) == 0);
ok_if(18, $poe_kernel->_data_ev_get_count_to(BOGUS_SESSION) == 0);
ok_unless(19, defined $poe_kernel->_data_ses_refcount(BOGUS_SESSION));

# Remove the alarm by name, for real.  We should be down to one timer
# (the original poll thing).
$poe_kernel->_data_ev_clear_alarm_by_name($poe_kernel, "timer");
check_references($poe_kernel, 20);

# Remove the last of the timers.  The Kernel session is the only
# reference left for it.
my @removed = $poe_kernel->_data_ev_clear_alarm_by_session($poe_kernel);
ok_if(22, @removed == 1);

# Verify that the removed timer is the correct one.  We still have the
# signal polling timer around there somewhere.
my ($removed_name, $removed_time, $removed_args) = @{$removed[0]};
ok_if(23, $removed_name eq "other-timer");
ok_if(24, $removed_time == 4);

check_references($poe_kernel, 25);

# Remove all events for the kernel session.  Now it should be able to
# finalize cleanly.
$poe_kernel->_data_ev_clear_session($poe_kernel);

# A final test.
ok_if(27, $poe_kernel->_data_ev_finalize());

results();
exit 0;


# Every time we cross-check a session for events and reference counts,
# there should be twice as many references as events.  This is because
# each event counts twice: once because the session sent the event,
# and again because the event was due for the session.  Check that the
# from- and to counts add up to the reference count, and that they are
# equal.

sub check_references {
  my ($session, $start_test) = @_;

  my $ref_count  = $poe_kernel->_data_ses_refcount($session);
  my $from_count = $poe_kernel->_data_ev_get_count_from($session);
  my $to_count   = $poe_kernel->_data_ev_get_count_to($session);
  my $check_sum  = $from_count + $to_count;

  ok_if(
    $start_test, $check_sum == $ref_count, "$ref_count should be $check_sum"
  );
  ok_if(
    $start_test + 1, $from_count == $to_count, "$from_count should be $to_count"
  );
}

