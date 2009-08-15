#!/usr/bin/perl -w

# Test the ASSERT_DATA code in POE::Kernel.  This involves a lot of
# dying.

use strict;
use lib qw(./mylib);

# _explain_resolve_failure
# session_alloc

use Test::More tests => 7;

sub POE::Kernel::ASSERT_DATA    () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok("POE") }

# Disable any "didn't call run" warnings.

POE::Kernel->run();

# Session resolution.

eval { $poe_kernel->signal(moo => "signal") };
ok(
  $@ && $@ =~ /Cannot resolve ``moo'' into a session reference/,
  "unresolvable session in signal"
);

eval { $poe_kernel->detach_child("moo") };
ok(
  $@ && $@ =~ /Cannot resolve ``moo'' into a session reference/,
  "unresolvable session in detach_child"
);

eval { $poe_kernel->post(moo => "bar") };
ok(
  $@ && $@ =~ /Cannot resolve ``moo'' into a session reference/,
  "unresolvable session in post"
);

eval { $poe_kernel->call(moo => "bar") };
ok(
  $@ && $@ =~ /Cannot resolve ``moo'' into a session reference/,
  "unresolvable session in call"
);

# Double session allocation.

eval { $poe_kernel->session_alloc($poe_kernel) };
ok(
  $@ && $@ =~ /session .*? already exists/s,
  "double session_alloc"
);

# Free POE::Kernel to catch some bizarre errors.  Requires us to force
# POE::Kernel's instance to go away.

$poe_kernel->_data_ses_free($poe_kernel);
eval { $poe_kernel->alarm_remove_all() };
ok(
  $@ && $@ =~ /unknown session in alarm_remove_all call/,
  "removing alarms from unknown session"
);

exit 0;
