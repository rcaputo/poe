#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./lib ../lib . ..);
use TestSetup;

use POE;

test_setup(9);

# Increment an extra reference count, and verify its value.

my $refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(1, $refcnt == 1);
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(2, $refcnt == 2);

# Remove it entirely, and verify that it's 1 again after
# incrementation.

$poe_kernel->_data_extref_remove($poe_kernel, "tag-1");
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(3, $refcnt == 1);

# Set a second reference count, then verify that both are reset.

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok_if(4, $refcnt == 1);

$poe_kernel->_data_extref_clear_session($poe_kernel);

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok_if(5, $refcnt == 1);
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok_if(6, $refcnt == 1);

# Only one session has an extra reference count.
ok_if(7, $poe_kernel->_data_extref_count() == 1);

# Extra references for the kernel should be two.  A nonexistent
# session should have none.
ok_if(8, $poe_kernel->_data_extref_count_ses($poe_kernel) == 1);
ok_if(9, $poe_kernel->_data_extref_count_ses("nothing") == 0);

# Clear the references, and make sure the subsystem shuts down
# cleanly.
$poe_kernel->_data_extref_dec($poe_kernel, "tag-1");
$poe_kernel->_data_extref_dec($poe_kernel, "tag-2");

# Ensure the subsystem shuts down ok.
$poe_kernel->_data_extref_finalize();

results();
exit 0;
