use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 46;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok("POE") }

# Verify that we have safe signals.
#
# We only verify that at least one signal is "safe".  Matching a
# larger set is HARD because the set of supported signals probably
# varies like crazy.

{ my @safe_signals = $poe_kernel->_data_sig_get_safe_signals();
  ok( grep(/^INT$/, @safe_signals), "at least SIGINT is available" );
}

# What happens if signals are initialized more than once?

$poe_kernel->_data_sig_initialize();

# Create some sessions for testing.

sub create_session {
  my $session = bless [ ], "POE::Session";
  my $sid     = $poe_kernel->_data_sid_allocate();

  $poe_kernel->_data_ses_allocate(
    $session,     # session
    $sid,         # sid
    $poe_kernel,  # parent
  );

  return($session, $sid);
}


# Add some signals for testing.

my ($ses_1, $sid_1) = create_session();
$poe_kernel->_data_sig_add($ses_1, "signal-1", "event-1");
$poe_kernel->_data_sig_add($ses_1, "signal-2", "event-2");

my ($ses_2, $sid_2) = create_session();
$poe_kernel->_data_sig_add($ses_2, "signal-2", "event-3");

# Verify that the signals were added, and also that nonexistent signal
# watchers don't cause false positives in this test.

ok(
  $poe_kernel->_data_sig_explicitly_watched("signal-1"),
  "signal-1 is explicitly watched"
);

ok(
  $poe_kernel->_data_sig_explicitly_watched("signal-2"),
  "signal-2 is explicitly watched"
);

ok(
  !$poe_kernel->_data_sig_explicitly_watched("signal-0"),
  "signal-0 is not explicitly watched"
);

# More detailed checks.  Test that each signal is watched by its
# proper session.

ok(
  $poe_kernel->_data_sig_is_watched_by_session("signal-1", $ses_1),
  "session 1 watches signal-1"
);

ok(
  $poe_kernel->_data_sig_is_watched_by_session("signal-2", $ses_1),
  "session 1 watches signal-2"
);

ok(
  !$poe_kernel->_data_sig_is_watched_by_session("signal-1", $ses_2),
  "session 2 does not watch signal-1"
);

# Make sure we can determine watchers for each signal.

# Single watcher test...
{ my %watchers = $poe_kernel->_data_sig_watchers("signal-1");
  ok(
    eq_hash(\%watchers, { $ses_1 => "event-1" }),
    "signal-1 maps to session 1 and event-1"
  );
}

# Multiple watcher test...
{ my %watchers = $poe_kernel->_data_sig_watchers("signal-2");
  ok(
    eq_hash(
      \%watchers, {
        $ses_1 => "event-2",
        $ses_2 => "event-3",
      }
    ),
    "signal-2 maps to session 1 and event-2; session 2 and event-3"
  );
}

# Remove one of the multiple signals, and verify that the remaining
# ones are correct.

$poe_kernel->_data_sig_remove($ses_1, "signal-2");

# Single watcher test...

{ my %watchers = $poe_kernel->_data_sig_watchers("signal-1");
  ok(
    eq_hash(\%watchers, { $ses_1 => "event-1" }),
    "signal-1 still maps to session 1 and event-1"
  );
}

# Multiple watcher test...

{ my %watchers = $poe_kernel->_data_sig_watchers("signal-2");
  ok(
    eq_hash(\%watchers, { $ses_2 => "event-3" }),
    "signal-2 still maps to session 2 and event-3"
  );
}

# Ad some more signals for one of the sessions, then clear all the
# signals for that session.  Verify that they're all added and cleaned
# up correctly.

$poe_kernel->_data_sig_add($ses_1, "signal-3", "event-3");
$poe_kernel->_data_sig_add($ses_1, "signal-4", "event-3");
$poe_kernel->_data_sig_add($ses_1, "signal-5", "event-3");
$poe_kernel->_data_sig_add($ses_1, "signal-6", "event-3");

{ my %watchers = $poe_kernel->_data_sig_watched_by_session($ses_1);
  ok(
    eq_hash(
      \%watchers,
      { "signal-1", "event-1",
        "signal-3", "event-3",
        "signal-4", "event-3",
        "signal-5", "event-3",
        "signal-6", "event-3",
      }
    ),
    "several signal watchers were added correctly"
  );
}

$poe_kernel->_data_sig_clear_session($ses_1);

{ my %watchers = $poe_kernel->_data_sig_watchers("signal-2");
  ok(
    eq_hash(\%watchers, { $ses_2 => "event-3" }),
    "cleared session isn't watching signal-2"
  );
}

# Check signal types.

ok(
  $poe_kernel->_data_sig_type("QUIT") == POE::Kernel::SIGTYPE_TERMINAL,
  "SIGQUIT is terminal"
);

ok(
  $poe_kernel->_data_sig_type("nonexistent") == POE::Kernel::SIGTYPE_BENIGN,
  "nonexistent signal is benign"
);

# Test the signal handling flag things.

$poe_kernel->_data_sig_reset_handled("QUIT");

{ my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok(!defined($tot), "SIGQUIT handled by zero sessions");
  ok($type == POE::Kernel::SIGTYPE_TERMINAL, "SIGQUIT is terminal");
  ok( eq_array($ses, []), "no sessions touched by SIGQUIT" );
}

# Touch a session with the signal.

$poe_kernel->_data_sig_touched_session(
  $ses_2,       # session
  "some event", # event
  0,            # handler retval (did not handle)
  "QUIT",       # signal
);

{ my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok(!defined($tot), "SIGQUIT handled by zero sessions");
  ok($type == POE::Kernel::SIGTYPE_TERMINAL, "SIGQUIT is terminal");
  ok( eq_array($ses, [ $ses_2 ]), "SIGQUIT touched correct session" );
}

$poe_kernel->_data_sig_handled();

{ my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok($tot == 1, "SIGQUIT handled by one session");
  ok($type == POE::Kernel::SIGTYPE_TERMINAL, "SIGQUIT is terminal");
  ok( eq_array($ses, [ $ses_2 ]), "SIGQUIT touched correct session" );
}

{ my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok($tot == 1, "SIGQUIT handled by one session");
  ok($type == POE::Kernel::SIGTYPE_TERMINAL, "SIGQUIT is terminal");
  ok( eq_array($ses, [ $ses_2 ]), "SIGQUIT touched correct session" );
}

$poe_kernel->_data_sig_reset_handled("nonexistent");

{ my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok(!defined($tot), "reset signal status = handled by zero sessions");
  ok(
    $type == POE::Kernel::SIGTYPE_BENIGN,
    "reset signal status = benign"
  );
  ok( eq_array($ses, []), "reset signal status = no sessions touched" );
}

# Benign signal the test session.  It doesn't handle the signal.  Try
# to free it.  Make sure it's not freed.
#
# -><- Currently the deprecated behavior is to free everything that
# has _data_sig_touched_session() called on it.  We can enable this
# test properly once the deprecated behavior is removed.
#
# -><- This test is itself not properly tested.

TODO: {
  my ($session, $sid) = create_session();

  $poe_kernel->_data_sig_reset_handled("nonexistent");

  # Clear the implicit handling.
  $poe_kernel->_data_sig_reset_handled("nonexistent");

  # Touch it again, but don't handle it.
  $poe_kernel->_data_sig_touched_session(
    $session,      # session
    "some event",  # event
    0,             # handler retval (did not handle)
    "nonexistent", # signal
  );

  my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok(!defined($tot), "nonexistent signal handled by zero sessions");
  ok(
    $type == POE::Kernel::SIGTYPE_BENIGN,
    "nonexistent signal is benign"
  );
  ok(
    eq_array($ses, [ $session ]),
    "nonexistent signal touched target session"
  );

  # Free a benignly-handled session.
  $poe_kernel->_data_sig_free_terminated_sessions();

  # TODO - Enable this test when the signal behavior changes.
  todo_skip "benign signal free test is for future behavior", 1;

  ok(
    $poe_kernel->_data_ses_exists($session),
    "unhandled benign signal does not free session"
  );
}

# Terminal signal the test session.  It handles the signal.  Try to
# free it.  Make sure it's not freed.
# 
# -><- Also tests future behavior.  Enable when _signal is removed.

TODO: {
  $poe_kernel->_data_sig_reset_handled("QUIT");

  $poe_kernel->_data_sig_touched_session(
    $ses_2,        # session
    "some event",  # event
    0,             # handler retval (did not handle)
    "QUIT",        # signal
  );

  $poe_kernel->_data_sig_handled();

  # What happens if the session is handled explicitly and implicitly?
  # Well, the implicit deprecation warning should not be triggered.
  $poe_kernel->_data_sig_touched_session(
    $ses_2,        # session
    "some event",  # event
    1,             # handler retval (did not handle)
    "QUIT",        # signal
  );

  # Now see if the session's freed.
  $poe_kernel->_data_sig_free_terminated_sessions();

  # TODO - Enable the following test when signal deprecations are
  # done.
  todo_skip "terminal signal free test is for future behavior", 1;

  ok(
    $poe_kernel->_data_ses_exists($ses_2),
    "handled terminal signal does not free session"
  );
}

# Terminal signal the test session.  It does not handle the signal.
# Try to free it.  Make sure it is freed.

$poe_kernel->_data_sig_reset_handled("QUIT");

$poe_kernel->_data_sig_touched_session(
  $ses_2,        # session
  "some event",  # event
  0,             # handler retval (did not handle)
  "QUIT",        # signal
);

{ my ($tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok(!defined($tot), "SIGQUIT handled by zero sessions");
  ok($type == POE::Kernel::SIGTYPE_TERMINAL, "SIGQUIT is terminal");
  ok( eq_array($ses, [ $ses_2 ]), "SIGQUIT touched session 2" );
}

$poe_kernel->_data_sig_free_terminated_sessions();
ok(
  !$poe_kernel->_data_ses_exists($ses_2),
  "unhandled terminal signal freed session 2"
);

# Nonmaskable signals terminate sessions no matter what.

{ my $ses = bless [ ], "POE::Session";
  my $sid = $poe_kernel->_data_sid_allocate();

  $poe_kernel->_data_ses_allocate(
    $ses,         # session
    $sid,         # sid
    $poe_kernel,  # parent
  );

  $poe_kernel->_data_sig_reset_handled("UIDESTROY");

  $poe_kernel->_data_sig_touched_session(
    $ses,          # session
    "some event",  # event
    0,             # handler retval (did not handle)
    "UIDESTROY",   # signal
  );

  $poe_kernel->_data_sig_handled();

  my ($tot, $type, $touched_ses) = $poe_kernel->_data_sig_handled_status();
  ok($tot == 1, "SIGUIDESTROY handled by zero sessions");
  ok(
    $type == POE::Kernel::SIGTYPE_NONMASKABLE,
    "SIGUIDESTROY is not maskable"
  );
  ok(
    eq_array([ $ses ], $touched_ses),
    "SIGUIDESTROY touched session correct session"
  );

  $poe_kernel->_data_sig_free_terminated_sessions();
  ok(
    !$poe_kernel->_data_ses_exists($ses),
    "handled SIGUIDESTROY freed target session anyway"
  );
}

# It's ok to clear signals from a nonexistent session, because not all
# sessions watch signals.  This exercises a branch not usually taken
# in the tests.

$poe_kernel->_data_sig_clear_session("nonexistent");

# Check whether anybody's watching a bogus signal.  This exercises a
# branch that's not normally taken in the tests.

ok(
  !$poe_kernel->_data_sig_is_watched_by_session("nonexistent", $ses_2),
  "session 2 isn't watching for a nonexistent signal"
);

# Ensure the data structures are clean when we're done.
ok($poe_kernel->_data_sig_finalize(), "POE::Resource::Signals finalized ok");

1;
