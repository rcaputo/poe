#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./lib ../lib . ..);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
BEGIN { open STDERR, ">./test-output.err" or die $!; }

use POE;

test_setup(64);

# Verify that we have safe signals.  -><- We only verify that we got
# some (at least one).  Matching signals vs. a known set is HARD
# because that known set probably varies like crazy.
{ my @safe_signals = $poe_kernel->_data_sig_get_safe_signals();
  ok_if(1, @safe_signals);
}

# Create some sessions for testing.
my $ses_1 = bless [ ], "POE::Session";
my $sid_1 = $poe_kernel->_data_sid_allocate();
$poe_kernel->_data_ses_allocate(
  $ses_1,       # session
  $sid_1,       # sid
  $poe_kernel,  # parent
);

my $ses_2 = bless [ ], "POE::Session";
my $sid_2 = $poe_kernel->_data_sid_allocate();
$poe_kernel->_data_ses_allocate(
  $ses_2,       # session
  $sid_2,       # sid
  $poe_kernel,  # parent
);

# Add some signals for testing.
$poe_kernel->_data_sig_add($ses_1, "signal-1", "event-1");
$poe_kernel->_data_sig_add($ses_1, "signal-2", "event-2");
$poe_kernel->_data_sig_add($ses_2, "signal-2", "event-3");

# Verify that the signals were added, and also that nonexistent signal
# watchers don't cause false positives in this test.
ok_if(2, $poe_kernel->_data_sig_explicitly_watched("signal-1"));
ok_if(3, $poe_kernel->_data_sig_explicitly_watched("signal-2"));
ok_unless(4, $poe_kernel->_data_sig_explicitly_watched("signal-0"));

# More detailed checks.  Test that each signal is watched by its
# proper session.
ok_if(
  5,
  $poe_kernel->_data_sig_is_watched_by_session("signal-1", $ses_1)
);
ok_if(
  6,
  $poe_kernel->_data_sig_is_watched_by_session("signal-2", $ses_1)
);
ok_unless(
  7,
  $poe_kernel->_data_sig_is_watched_by_session("signal-1", $ses_2)
);

# Make sure we can determine watchers for each signal.

# Single watcher test...
{ my %watchers = $poe_kernel->_data_sig_watchers("signal-1");
  ok_if(8, scalar keys %watchers == 1);
  ok_if(9, $watchers{$ses_1} eq "event-1");
}

# Multiple watcher test...
{ my %watchers = $poe_kernel->_data_sig_watchers("signal-2");
  ok_if(10, scalar keys %watchers == 2);
  ok_if(11, $watchers{$ses_1} eq "event-2");
  ok_if(12, $watchers{$ses_2} eq "event-3");
}

# Remove one of the multiple signals, and verify that the remaining
# ones are correct.
$poe_kernel->_data_sig_remove($ses_1, "signal-2");

# Single watcher test...
{ my %watchers = $poe_kernel->_data_sig_watchers("signal-1");
  ok_if(13, scalar keys %watchers == 1);
  ok_if(14, $watchers{$ses_1} eq "event-1");
}

# Multiple watcher test...
{ my %watchers = $poe_kernel->_data_sig_watchers("signal-2");
  ok_if(15, scalar keys %watchers == 1);
  ok_if(16, $watchers{$ses_2} eq "event-3");
}

# Add another signal for one of the sessions, then clear all signals
# by that session.  Verify that everything is as it should be.
$poe_kernel->_data_sig_add($ses_1, "signal-3", "event-3");
$poe_kernel->_data_sig_add($ses_1, "signal-4", "event-3");
$poe_kernel->_data_sig_add($ses_1, "signal-5", "event-3");
$poe_kernel->_data_sig_add($ses_1, "signal-6", "event-3");

{ my %watchers = $poe_kernel->_data_sig_watched_by_session($ses_1);
  ok_if(17, scalar keys %watchers == 5);
  ok_if(18, $watchers{"signal-1"} eq "event-1");
  ok_if(19, $watchers{"signal-3"} eq "event-3");
  ok_if(20, $watchers{"signal-4"} eq "event-3");
  ok_if(21, $watchers{"signal-5"} eq "event-3");
  ok_if(22, $watchers{"signal-6"} eq "event-3");
}

$poe_kernel->_data_sig_clear_session($ses_1);

{ my %watchers = $poe_kernel->_data_sig_watchers("signal-2");
  ok_if(23, scalar keys %watchers == 1);
  ok_if(24, $watchers{$ses_2} eq "event-3");
}

# Check signal types.
{ my $sig_type;

  ok_if(
    25,
    $poe_kernel->_data_sig_type("QUIT") == POE::Kernel::SIGTYPE_TERMINAL
  );
  ok_if(
    26,
    $poe_kernel->_data_sig_type("nonexistent") ==
      POE::Kernel::SIGTYPE_BENIGN
  );
}

# Test the signal handling flag things.
$poe_kernel->_data_sig_reset_handled("QUIT");
$poe_kernel->_data_sig_clear_handled_flags();

{ my ($ex, $im, $tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok_unless(27, $ex);
  ok_unless(28, $im);
  ok_unless(29, defined $tot);
  ok_if(30, $type == POE::Kernel::SIGTYPE_TERMINAL);
  ok_if(31, @$ses == 0);
}

$poe_kernel->_data_sig_touched_session(
  $ses_2,       # session
  "some event", # event
  0,            # handler retval (did not handle)
  "QUIT",       # signal
);

{ my ($ex, $im, $tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok_unless(32, $ex);
  ok_unless(33, $im);
  ok_if(34, $tot == 0);
  ok_if(35, $type == POE::Kernel::SIGTYPE_TERMINAL);
  ok_if(36, @$ses == 1);
  ok_if(37, $ses->[0] == $ses_2);
}

$poe_kernel->_data_sig_handled();

{ my ($ex, $im, $tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok_if(38, $ex);
  ok_unless(39, $im);
  ok_if(40, $tot == 1);
  ok_if(41, $type == POE::Kernel::SIGTYPE_TERMINAL);
  ok_if(42, @$ses == 1);
  ok_if(43, $ses->[0] == $ses_2);
}

$poe_kernel->_data_sig_clear_handled_flags();

{ my ($ex, $im, $tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok_unless(44, $ex);
  ok_unless(45, $im);
  ok_if(46, $tot == 1);
  ok_if(47, $type == POE::Kernel::SIGTYPE_TERMINAL);
  ok_if(48, @$ses == 1);
  ok_if(49, $ses->[0] == $ses_2);
}

$poe_kernel->_data_sig_reset_handled("nonexistent");

{ my ($ex, $im, $tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok_unless(50, $ex);
  ok_unless(51, $im);
  ok_unless(52, defined $tot);
  ok_if(53, $type == POE::Kernel::SIGTYPE_BENIGN);
  ok_if(54, @$ses == 0);
}

# Benign signal the test session.  It doesn't handle the signal.  Try
# to free it.  Make sure it's not freed.
#
# -><- Currently the deprecated behavior is to free everything that
# has _data_sig_touched_session() called on it.  We can enable this
# test properly once the deprecated behavior is removed.

#$poe_kernel->_data_sig_reset_handled("nonexistent");
#$poe_kernel->_data_sig_touched_session(
#  $ses_2,        # session
#  "some event",  # event
#  0,             # handler retval (did not handle)
#  "nonexistent", # signal
#);
#$poe_kernel->_data_sig_clear_handled_flags();
#$poe_kernel->_data_sig_free_terminated_sessions();
#ok_if(55, $poe_kernel->_data_ses_exists($ses_2));

ok(55, "skipped: tests future behavior");

# Terminal signal the test session.  It handles the signal.  Try to
# free it.  Make sure it's not freed.
# 
# -><- Also tests future behavior.  Uncomment when _signal is removed.

#$poe_kernel->_data_sig_reset_handled("QUIT");
#$poe_kernel->_data_sig_clear_handled_flags();
#$poe_kernel->_data_sig_handled();
#$poe_kernel->_data_sig_touched_session(
#  $ses_2,        # session
#  "some event",  # event
#  0,             # handler retval (did not handle)
#  "QUIT",        # signal
#);
#$poe_kernel->_data_sig_free_terminated_sessions();
#ok_if(56, $poe_kernel->_data_ses_exists($ses_2));

ok(56, "skipped: tests future behavior");

# Terminal signal the test session.  It does not handle the signal.
# Try to free it.  Make sure it is freed.
$poe_kernel->_data_sig_reset_handled("QUIT");
$poe_kernel->_data_sig_clear_handled_flags();
$poe_kernel->_data_sig_touched_session(
  $ses_2,        # session
  "some event",  # event
  0,             # handler retval (did not handle)
  "QUIT",        # signal
);

{ my ($ex, $im, $tot, $type, $ses) = $poe_kernel->_data_sig_handled_status();
  ok_unless(57, $ex);
  ok_unless(58, $im);
  ok_if(59, $tot == 0);
  ok_if(60, $type == POE::Kernel::SIGTYPE_TERMINAL);
  ok_if(61, @$ses == 1);
  ok_if(62, $ses->[0] == $ses_2);
}

$poe_kernel->_data_sig_free_terminated_sessions();
ok_unless(63, $poe_kernel->_data_ses_exists($ses_2));

# Ensure the data structures are clean when we're done.
ok_if(64, $poe_kernel->_data_sig_finalize());

results();
exit 0;
