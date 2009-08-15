use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 29;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok("POE") }

# Increment an extra reference count, and verify its value.

my $refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok($refcnt == 1, "tag-1 incremented to 1");

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok($refcnt == 2, "tag-1 incremented to 2");

# Three session references: One for sending events, one for receiving
# events, and one for tag-1.  (No matter how many times you increment
# a single tag, it only counts as one session reference.)

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == 3,
  "POE::Kernel has proper number of references"
);

# Attempt to remove some strange tag.

eval { $poe_kernel->_data_extref_remove($poe_kernel, "nonexistent") };
ok(
  $@ && $@ =~ /removing extref for nonexistent tag/,
  "can't remove nonexistent tag from a session"
);

# Remove it entirely, and verify that it's 1 again after incrementing
# again.

$poe_kernel->_data_extref_remove($poe_kernel, "tag-1");
$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok($refcnt == 1, "tag-1 count cleared/incremented to 1");

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == 3,
  "POE::Kernel still has five references"
);

# Set a second reference count, then verify that both are reset.

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok($refcnt == 1, "tag-2 incremented to 1");

# Setting a second tag increments the master reference count.

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == 4,
  "POE::Kernel reference count incremented with new tag"
);

# Clear all the extra references for the session, and verify that the
# master reference count is back to 2 (one "from"; one "to").

$poe_kernel->_data_extref_clear_session($poe_kernel);
ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == 2,
  "cleared tags reduce session refcount properly"
);

eval { $poe_kernel->_data_extref_remove($poe_kernel, "nonexistent") };
ok(
  $@ && $@ =~ /removing extref from session without any/,
  "can't remove tag from a session without any"
);

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-1");
ok($refcnt == 1, "tag-1 incremented back to 1");

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok($refcnt == 1, "tag-2 incremented back to 1");

$refcnt = $poe_kernel->_data_extref_inc($poe_kernel, "tag-2");
ok($refcnt == 2, "tag-2 incremented back to 2");

# Only one session has an extra reference count.

ok(
  $poe_kernel->_data_extref_count() == 1,
  "only one session has extra references"
);

# Extra references for the kernel should be two.  A nonexistent
# session should have none.

ok(
  $poe_kernel->_data_extref_count_ses($poe_kernel) == 2,
  "POE::Kernel has two extra references"
);

ok(
  $poe_kernel->_data_extref_count_ses("nothing") == 0,
  "nonexistent session has no extra references"
);

# What happens if decrementing an extra reference for a tag that
# doesn't exist?

eval { $poe_kernel->_data_extref_dec($poe_kernel, "nonexistent") };
ok(
  $@ && $@ =~ /decrementing extref for nonexistent tag/,
  "can't decrement an extref if a session doesn't have it"
);

# Clear the references, and make sure the subsystem shuts down
# cleanly.

{ ok(
    $poe_kernel->_data_extref_dec($poe_kernel, "tag-1") == 0,
    "tag-1 decremented to 0"
  );

  ok(
    $poe_kernel->_data_extref_count_ses($poe_kernel) == 1,
    "POE::Kernel has one extra reference"
  );

  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 3,
    "POE::Kernel reference count decremented along with tag"
  );
}

{ ok(
    $poe_kernel->_data_extref_dec($poe_kernel, "tag-2") == 1,
    "tag-2 decremented to 1"
  );

  ok(
    $poe_kernel->_data_extref_count_ses($poe_kernel) == 1,
    "POE::Kernel still has one extra reference"
  );

  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 3,
    "POE::Kernel reference count not decremented yet"
  );
}

{ ok(
    $poe_kernel->_data_extref_dec($poe_kernel, "tag-2") == 0,
    "tag-2 decremented to 0"
  );

  ok(
    $poe_kernel->_data_extref_count_ses($poe_kernel) == 0,
    "POE::Kernel has no extra references"
  );

  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 2,
    "POE::Kernel reference count decremented again"
  );
}

# Catch some errors.

eval { $poe_kernel->_data_extref_dec($poe_kernel, "nonexistent") };
ok(
  $@ && $@ =~ /decrementing extref for session without any/,
  "can't decrement an extref if a session doesn't have any"
);

# Clear the session again, to exercise some code that otherwise
# wouldn't be.

$poe_kernel->_data_extref_clear_session($poe_kernel);

# Ensure the subsystem shuts down ok.

ok(
  $poe_kernel->_data_extref_finalize(),
  "POE::Resource::Extrefs finalized ok"
);

1;
