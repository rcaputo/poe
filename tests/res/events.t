#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./mylib ../mylib . ..);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

sub BOGUS_SESSION () { 31415 }

test_setup(33);

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

# Kernel should have two events due.  A nonexistent session should
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

# Kernel should have two events due.
ok_if(7, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 2);
ok_if(8, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 2);

# Signal poll timer (x2), performance timer (x2), and session.
# From/to have been dispatched.  TODO - Why not 5?
ok_if(9, $poe_kernel->_data_ses_refcount($poe_kernel) == 4);

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

# Added eight to the reference count.  From/to for each of four timers.
ok_if(10, $poe_kernel->_data_ses_refcount($poe_kernel) == 12);
ok_if(11, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 6);
ok_if(12, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 6);

# Remove one of the alarms by its ID.  The reference count should be 8.
my ($time, $event) = $poe_kernel->_data_ev_clear_alarm_by_id(
  $poe_kernel, $ids[1]
);
ok_if(13, $time == 2);
ok_if(14, $event->[POE::Kernel::EV_NAME] eq "timer");

ok_if(15, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 5);
ok_if(16, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 5);
ok_if(17, $poe_kernel->_data_ses_refcount($poe_kernel) == 10);

# Remove an alarm by name, except that this is for a nonexistent
# session.
$poe_kernel->_data_ev_clear_alarm_by_name(BOGUS_SESSION, "timer");
ok_if(18, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 5);
ok_if(19, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 5);
ok_if(20, $poe_kernel->_data_ses_refcount($poe_kernel) == 10);

ok_if(21, $poe_kernel->_data_ev_get_count_from(BOGUS_SESSION) == 0);
ok_if(22, $poe_kernel->_data_ev_get_count_to(BOGUS_SESSION) == 0);
ok_unless(23, defined $poe_kernel->_data_ses_refcount(BOGUS_SESSION));

# Remove the alarm by name, for real.  We should be down to one timer
# (the original poll thing).
$poe_kernel->_data_ev_clear_alarm_by_name($poe_kernel, "timer");

ok_if(24, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 3);
ok_if(25, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 3);
ok_if(26, $poe_kernel->_data_ses_refcount($poe_kernel) == 6);

# Remove the last of the timers.  The Kernel session is the only
# reference left for it.
my @removed = $poe_kernel->_data_ev_clear_alarm_by_session($poe_kernel);
ok_if(27, @removed == 1);

# Verify that the removed timer is the correct one.  We still have the
# signal polling timer around there somewhere.
my ($removed_name, $removed_time, $removed_args) = @{$removed[0]};
ok_if(28, $removed_name eq "other-timer");
ok_if(29, $removed_time == 4);

ok_if(30, $poe_kernel->_data_ev_get_count_from($poe_kernel) == 2);
ok_if(31, $poe_kernel->_data_ev_get_count_to($poe_kernel) == 2);
ok_if(32, $poe_kernel->_data_ses_refcount($poe_kernel) == 4);

# Remove all events for the kernel session.  Now it should be able to
# finalize cleanly.
$poe_kernel->_data_ev_clear_session($poe_kernel);

# A final test.
ok_if(33, $poe_kernel->_data_ev_finalize());

results();
exit 0;
