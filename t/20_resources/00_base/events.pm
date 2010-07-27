# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 38;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

BEGIN { use_ok("POE") }

sub BOGUS_SESSION () { 31415 }

my $baseline_event = 0;
$baseline_event++ if POE::Kernel::TRACE_STATISTICS; # stat poll event

my $baseline_refcount = 0;
$baseline_refcount += 2 if POE::Kernel::TRACE_STATISTICS; # stat poll event

# This subsystem is still very closely tied to POE::Kernel, so we
# can't call initialize ourselves.  TODO Separate it, if possible,
# enough to make this feasible.

{ # Create a new event, and verify that it's good.

  my $event_id = $poe_kernel->_data_ev_enqueue(
    $poe_kernel,  # session
    $poe_kernel,  # source_session
    "event",      # event
    POE::Kernel::ET_ALARM,  # event type
    [],           # etc
    __FILE__,     # file
    __LINE__,     # line
    "called_from",# caller state
    0,            # time (beginning thereof)
  );

  # Event 1 is the kernel's performance poll timer.
  is(
    $event_id, $baseline_event + 1,
    "first user created event has correct ID"
  );

  # Kernel should therefore have one events due.
  # A nonexistent session should have zero.

  is(
    $poe_kernel->_data_ev_get_count_from($poe_kernel), $baseline_event,
    "POE::Kernel has enqueued correct number of events"
  );

  is(
    $poe_kernel->_data_ev_get_count_to($poe_kernel), $baseline_event + 1,
    "POE::Kernel has three events enqueued for it"
  );

  is(
    $poe_kernel->_data_ev_get_count_from("nothing"), 0,
    "unknown session has enqueued no events"
  );

  is(
    $poe_kernel->_data_ev_get_count_to("nothing"), 0,
    "unknown session has no events enqueued for it"
  );

  # Performance timer only counts once now.

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel), $baseline_refcount + 1,
    "POE::Kernel's timer count is correct"
  );
}

{ # Dispatch due events, and stuff.

  $poe_kernel->_data_ev_dispatch_due();
  check_references(
    $poe_kernel, 0, 0, 0, "after due events are dispatched"
  );
}

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
      undef,                 # called from state
      $_,                    # time
    )
  );
}

# The from and to counts should add up to the reference count.

check_references(
  $poe_kernel, 0, 0, 4, "after some timers are enqueued"
);

{ # Remove one of the alarms by its ID.

  my ($time, $event) = $poe_kernel->_data_ev_clear_alarm_by_id(
    $poe_kernel, $ids[1]
  );

  is($time, 2, "removed event has the expected due time");
  is(
    $event->[POE::Kernel::EV_NAME], "timer",
    "removed event has the expected name"
  );

  check_references(
    $poe_kernel, 0, 0, 3, "after a single named event is removed"
  );
}

{ # Try to remove a nonexistent alarm by the ID it would have if it
  # did exist, except it doesn't.

  my ($time, $event) = $poe_kernel->_data_ev_clear_alarm_by_id(
    $poe_kernel, 8675309
  );

  ok(!defined($time), "can't clear bogus alarm by nonexistent ID");
  check_references(
    $poe_kernel, 0, 0, 3, "after trying to clear a bogus alarm"
  );
}

# Remove an alarm by name, except that this is for a nonexistent
# session.

$poe_kernel->_data_ev_clear_alarm_by_name(BOGUS_SESSION, "timer");
check_references(
  $poe_kernel, 0, 0, 3, "after removing timers from a bogus session"
);

is(
  $poe_kernel->_data_ev_get_count_from(BOGUS_SESSION), 0,
  "bogus session has created no events"
);

is(
  $poe_kernel->_data_ev_get_count_to(BOGUS_SESSION), 0,
  "bogus session has no events enqueued for it"
);

# Remove the alarm by name, for real.  We should be down to one timer
# (the original poll thing).

$poe_kernel->_data_ev_clear_alarm_by_name($poe_kernel, "timer");
check_references(
  $poe_kernel, 0, 0, 1, "after removing 'timer' by name"
);

{ # Try to remove timers from some other (nonexistent should be ok)
  # session.

  my @removed = $poe_kernel->_data_ev_clear_alarm_by_session(8675309);
  is(@removed, 0, "didn't remove alarm from nonexistent session");
}

{ # Remove the last of the timers.  The Kernel session is the only
  # reference left for it.

  my @removed = $poe_kernel->_data_ev_clear_alarm_by_session($poe_kernel);
  is(@removed, 1, "removed the last alarm successfully");

  # Verify that the removed timer is the correct one.  We still have
  # the signal polling timer around there somewhere.
  my ($removed_name, $removed_time, $removed_args) = @{$removed[0]};
  is($removed_name, "other-timer", "last alarm had the corrent name");
  is($removed_time, 4, "last alarm had the corrent due time");

  check_references(
    $poe_kernel, 0, 0, 0, "after clearing all alarms for a session"
  );
}

# Remove all events for the kernel session.  Now it should be able to
# finalize cleanly.
$poe_kernel->_data_ev_clear_session($poe_kernel);

{ # Catch a trap when enqueuing an event for a nonexistent session.

  eval {
    $poe_kernel->_data_ev_enqueue(
      "moo",                  # dest session
      "moo",                  # source session
      "event",                # event name
      POE::Kernel::ET_ALARM,  # event type
      [],                     # etc
      __FILE__,               # file
      __LINE__,               # line
      undef,                  # called from state
      1,                      # due time
    );
  };
  ok(
    $@ && $@ =~ /can't enqueue event .*? for nonexistent session/,
    "trap while enqueuing event for non-existent session"
  );
}

{ # Exercise _data_ev_clear_session when events are sent from one
  # session to another.

  my $session = POE::Session->create(
    inline_states => {
      _start => sub { },
      _stop  => sub { },
    }
  );

  $poe_kernel->_data_ev_enqueue(
    $session,               # dest session
    $poe_kernel,            # source session
    "event-1",              # event name
    POE::Kernel::ET_POST,   # event type
    [],                     # etc
    __FILE__,               # file
    __LINE__,               # line
    undef,                  # called from state
    1,                      # due time
  );

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel,            # dest session
    $session,               # source session
    "event-2",              # event name
    POE::Kernel::ET_POST,   # event type
    [],                     # etc
    __FILE__,               # file
    __LINE__,               # line
    undef,                  # called from state
    2,                      # due time
  );

  check_references(
    $poe_kernel, 1, 1, 1, "after creating inter-session messages"
  );

  $poe_kernel->_data_ev_clear_session($session);

  check_references(
    $poe_kernel, 1, 0, 0, "after clearing inter-session messages"
  );

  $poe_kernel->_data_ev_clear_session($poe_kernel);

  check_references(
    $poe_kernel, 1, 0, 0, "after clearing kernel messages"
  );
}

# A final test.

ok(
  $poe_kernel->_data_ev_finalize(),
  "POE::Resource::Events finalized cleanly"
);

# END OF EXECUTION HERE, BUT I CAN'T USE EXIT

# Every time we cross-check a session for events and reference counts,
# there should be twice as many references as events.  This is because
# each event counts twice: once because the session sent the event,
# and again because the event was due for the session.  Check that the
# from- and to counts add up to the reference count, and that they are
# equal.
#
# The "base" references are ones from sources other than events.  In
# later tests, they're from the addition of another session.

sub check_references {
  my ($session, $base_ref, $expected_from, $expected_to, $when) = @_;

  my $from_count = $poe_kernel->_data_ev_get_count_from($session);
  my $to_count   = $poe_kernel->_data_ev_get_count_to($session);

  # Reference count stopped being simply the from + to + base counts.
  #my $ref_count  = $poe_kernel->_data_ses_refcount($session);
  #my $check_sum  = $from_count + $to_count + $base_ref;
  #is($check_sum, $ref_count, "refcnts $ref_count == $check_sum $when");

  is(
    $from_count, $expected_from,
    "from evcount $from_count == $expected_from $when"
  );
  is(
    $to_count, $expected_to,
    "to evcount $to_count == $expected_to $when"
  );
}

# We created a session, so run it.
POE::Kernel->run();

1;
