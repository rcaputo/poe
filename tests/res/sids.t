#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./mylib ../mylib ./lib ../lib ../../lib);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

test_setup(5);

# Allocate a session ID.  It starts at 2 because POE::Kernel's virtual
# session has already been allocated.
my $sid = $poe_kernel->_data_sid_allocate();
ok_if(1, $sid == 2);

# Set an ID for a session.
$poe_kernel->_data_sid_set($sid, "session");

# Ensure that the session ID resolves.
my $resolved_session = $poe_kernel->_data_sid_resolve($sid);
ok_if(2, $resolved_session eq "session");

# Remove the ID from the session.  This relies on a side effect of the
# remove function that returns the removed value.  That may change in
# the future.
my $removed = $poe_kernel->_data_sid_clear("session");
ok_if(3, $removed eq "session");

# POE::Kernel itself has allocated a SID.  Remove that.  This also
# relies on undocumented side effects that can change at any time.
$removed = $poe_kernel->_data_sid_clear($poe_kernel);
ok_if(4, $removed eq $poe_kernel);

# Finalize the subsystem and ensure it shut down cleanly.
ok_if(5, $poe_kernel->_data_sid_finalize());

results();
exit 0;
