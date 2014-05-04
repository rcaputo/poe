# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 7;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

BEGIN { use_ok("POE") }

# Allocate a session ID.  It starts at 2 because POE::Kernel's virtual
# session has already been allocated.

my $sid = $poe_kernel->_data_sid_allocate();
ok($sid == 1, "first user SID is expected (got $sid)");

# Set an ID for a session.

$poe_kernel->_data_sid_set($sid, "session");

# Ensure that the session ID resolves.

my $resolved_session = $poe_kernel->_data_sid_resolve($sid);
ok($resolved_session eq "session", "session ID resolves correctly");

# Remove the ID from the session.  This relies on a side effect of the
# remove function that returns the removed value.  That may change in
# the future.

my $removed = $poe_kernel->_data_sid_clear($sid);
ok($removed eq "session", "session ID $sid removes $removed correctly");

# What happens if a session doesn't exist?

eval { $poe_kernel->_data_sid_clear("session") };
ok(
  $@ && $@ =~ /unknown SID/,
  "can't clear a sid for a nonexistent session"
);

# POE::Kernel itself has allocated a SID.  Remove that.  This also
# relies on undocumented side effects that can change at any time.

$removed = $poe_kernel->_data_sid_clear($poe_kernel->ID);
ok($removed eq $poe_kernel, "successfully removed POE::Kernel's SID");

# Finalize the subsystem and ensure it shut down cleanly.

ok($poe_kernel->_data_sid_finalize(), "POE::Resource::SIDs finalized ok");

1;
