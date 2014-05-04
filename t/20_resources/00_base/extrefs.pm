# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 31;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

BEGIN { use_ok("POE") }

# Base reference count.
my $base_refcount = 0;

# Increment an extra reference count, and verify its value.

my $refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-1");
is($refcnt, 1, "tag-1 incremented to 1");

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-1");
is($refcnt, 2, "tag-1 incremented to 2");

# Baseline plus one reference: tag-1.  (No matter how many times you
# increment a single tag, it only counts as one session reference.
# This may change if the utility of the reference counts adding up
# outweighs the overhead of managing the session reference more.)

is(
  $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 1,
  "POE::Kernel properly counts tag-1 extra reference"
);

# Attempt to remove some strange tag.

eval { $poe_kernel->_data_extref_remove($poe_kernel->ID, "nonexistent") };
ok(
  $@ && $@ =~ /removing extref for nonexistent tag/,
  "can't remove nonexistent tag from a session"
);

is(
  $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 1,
  "POE::Kernel reference count unchanged"
);

# Remove it entirely, and verify that it's 1 again after incrementing
# again.

$poe_kernel->_data_extref_remove($poe_kernel->ID, "tag-1");
is(
  $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 0,
  "clear reset reference count to baseline"
);

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-1");
is($refcnt, 1, "tag-1 count cleared/incremented to 1");
is(
  $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 1,
  "increment after clear"
);

# Set a second reference count, then verify that both are reset.

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-2");
is($refcnt, 1, "tag-2 incremented to 1");

# Setting a second tag increments the master reference count.

is(
  $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 2,
  "POE::Kernel reference count incremented with new tag"
);

# Clear all the extra references for the session, and verify that the
# master reference count is back to the baseline.

$poe_kernel->_data_extref_clear_session($poe_kernel->ID);
is(
  $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount,
  "clearing all extrefs brings count to baseline"
);

eval { $poe_kernel->_data_extref_remove($poe_kernel->ID, "nonexistent") };
ok(
  $@ && $@ =~ /removing extref from session without any/,
  "can't remove tag from a session without any"
);

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-1");
is($refcnt, 1, "tag-1 incremented back to 1");

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-2");
is($refcnt, 1, "tag-2 incremented back to 1");

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel->ID, "tag-2");
is($refcnt, 2, "tag-2 incremented back to 2");

# Only one session has an extra reference count.

is(
  $poe_kernel->_data_extref_count(), 1,
  "only one session has extra references"
);

# Extra references for the kernel should be two.  A nonexistent
# session should have none.

is(
  $poe_kernel->_data_extref_count_ses($poe_kernel->ID), 2,
  "POE::Kernel has two extra references"
);

is(
  $poe_kernel->_data_extref_count_ses("nothing"), 0,
  "nonexistent session has no extra references"
);

# What happens if decrementing an extra reference for a tag that
# doesn't exist?

eval { $poe_kernel->_data_extref_dec($poe_kernel->ID, "nonexistent") };
ok(
  $@ && $@ =~ /decrementing extref for nonexistent tag/,
  "can't decrement an extref if a session doesn't have it"
);

# Clear the references, and make sure the subsystem shuts down
# cleanly.

{ is(
    $poe_kernel->_data_extref_dec($poe_kernel->ID, "tag-1"), 0,
    "tag-1 decremented to 0"
  );

  is(
    $poe_kernel->_data_extref_count_ses($poe_kernel->ID), 1,
    "POE::Kernel has one extra reference"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 1,
    "POE::Kernel reference count decremented along with tag"
  );
}

{ is(
    $poe_kernel->_data_extref_dec($poe_kernel->ID, "tag-2"), 1,
    "tag-2 decremented to 1"
  );

  is(
    $poe_kernel->_data_extref_count_ses($poe_kernel->ID), 1,
    "POE::Kernel still has one extra reference"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 1,
    "POE::Kernel reference count not decremented yet"
  );
}

{ is(
    $poe_kernel->_data_extref_dec($poe_kernel->ID, "tag-2"), 0,
    "tag-2 decremented to 0"
  );

  is(
    $poe_kernel->_data_extref_count_ses($poe_kernel->ID), 0,
    "POE::Kernel has no extra references"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount,
    "POE::Kernel reference count decremented again"
  );
}

# Catch some errors.

eval { $poe_kernel->_data_extref_dec($poe_kernel->ID, "nonexistent") };
ok(
  $@ && $@ =~ /decrementing extref for session without any/,
  "can't decrement an extref if a session doesn't have any"
);

# Clear the session again, to exercise some code that otherwise
# wouldn't be.

$poe_kernel->_data_extref_clear_session($poe_kernel->ID);

# Ensure the subsystem shuts down ok.

ok(
  $poe_kernel->_data_extref_finalize(),
  "POE::Resource::Extrefs finalized ok"
);

1;
