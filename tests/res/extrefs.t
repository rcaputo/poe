#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./lib ../lib . ..);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

test_setup(14);

# Increment an extra reference count, and verify its value.

my $refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(1, $refcnt == 1);
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(2, $refcnt == 2);

# Three master reference counts: One for POE::Kernel's virtual
# session, one for its signal polling timer, and ONLY ONE for both
# tag-1 extra references.
ok_if(3, $poe_kernel->_data_ses_refcount($poe_kernel) == 3);

# Remove it entirely, and verify that it's 1 again after
# incrementation.

$poe_kernel->_data_extref_remove($poe_kernel, "tag-1");
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(4, $refcnt == 1);

# Decrementing the tag does not remove the master reference count from
# the session, because the tag still has a positive count.
ok_if(5, $poe_kernel->_data_ses_refcount($poe_kernel) == 3);

# Set a second reference count, then verify that both are reset.

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok_if(6, $refcnt == 1);

# Setting a second tag increments the master reference count.
#
# -><- We could probably get away with only having one master
# reference count if any "extra" references are allocated.  This might
# be faster since we don't need to track two counts for these
# operations.
ok_if(7, $poe_kernel->_data_ses_refcount($poe_kernel) == 4);

# Clear all the extra references for the session, and verify that the
# master reference count is back to 2 (signal poll timer, session
# itself).
$poe_kernel->_data_extref_clear_session($poe_kernel);
ok_if(8, $poe_kernel->_data_ses_refcount($poe_kernel) == 2);

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(9, $refcnt == 1);
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok_if(10, $refcnt == 1);

# Only one session has an extra reference count.
ok_if(11, $poe_kernel->_data_extref_count() == 1);

# Extra references for the kernel should be two.  A nonexistent
# session should have none.
ok_if(12, $poe_kernel->_data_extref_count_ses($poe_kernel) == 2);
ok_if(13, $poe_kernel->_data_extref_count_ses("nothing") == 0);

# Clear the references, and make sure the subsystem shuts down
# cleanly.
$poe_kernel->_data_extref_dec($poe_kernel, "tag-1");
$poe_kernel->_data_extref_dec($poe_kernel, "tag-2");

# Under normal circumstances, the subsystem will shut down after being
# finalized.
$poe_kernel->_data_extref_clear_session($poe_kernel);

# Ensure the subsystem shuts down ok.
ok_if(14, $poe_kernel->_data_extref_finalize());

results();
exit 0;
