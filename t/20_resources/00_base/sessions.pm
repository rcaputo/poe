# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 58;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

BEGIN { use_ok("POE") }

# POE::Kernel is used as a parent session.  Gather a baseline
# reference count for it.  Its value will be used for other tests.

my $base_kernel_refcount = $poe_kernel->_data_ses_refcount($poe_kernel->ID);

is($poe_kernel->_data_ses_count(), 1, "only POE::Kernel exists");

# Allocate a dummy session for testing.

my $child     = bless [ ], "POE::Session";
my $child_sid = $poe_kernel->_data_sid_allocate();
$child->_set_id($child_sid);

$poe_kernel->_data_ses_allocate(
  $child,          # session
  $child_sid,      # sid
  $poe_kernel->ID, # parent
);

my $base_child_refcount = $poe_kernel->_data_ses_refcount($child_sid);

# Play a brief game with reference counts.  Make sure negative ones
# cause errors.

eval { $poe_kernel->_data_ses_refcount_dec($child_sid) };
ok(
  $@ && $@ =~ /reference count went below zero/,
  "trap on negative reference count"
);

is(
  $poe_kernel->_data_ses_refcount($child_sid), $base_child_refcount - 1,
  "negative reference count"
);

$poe_kernel->_data_ses_refcount_inc($child_sid);
is(
  $poe_kernel->_data_ses_refcount($child_sid), $base_child_refcount,
  "incremented reference count is back to base"
);

# Ensure that the session's ID was set.

is(
  $poe_kernel->_data_sid_resolve($child_sid), $child,
  "child session's ID is correct"
);

# Ensure parent/child referential integrity.

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  is_deeply(
    \@children, [ $child ],
    "POE::Kernel has only the child session"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount + 1,
    "POE::Kernel's refcount incremented by child"
  );

  my $parent = $poe_kernel->_data_ses_get_parent($child_sid);
  is($parent, $poe_kernel, "child's parent is POE::Kernel");

  ok(
    $poe_kernel->_data_ses_is_child($poe_kernel->ID, $child_sid),
    "child is child of POE::Kernel"
  );

  is($poe_kernel->_data_ses_count(), 2, "two sessions now");
}

# Try to free POE::Kernel while it has a child session.

eval { $poe_kernel->_data_ses_free($poe_kernel->ID) };
ok(
  $@ && $@ =~ /no parent to give children to/,
  "can't free POE::Kernel while it has children"
);

# A variety of session resolution tests.

is(
  $poe_kernel->_data_ses_resolve("$child"), $child,
  "stringified reference resolves to blessed one"
);

ok(
  !defined($poe_kernel->_data_ses_resolve("nonexistent")),
  "nonexistent stringy reference doesn't resolve"
);

is(
  $poe_kernel->_data_ses_resolve_to_id($child), $child_sid,
  "session reference $child resolves to ID"
);

ok(
  !defined($poe_kernel->_data_ses_resolve_to_id("nonexistent")),
  "nonexistent session reference doesn't resolve"
);

# Create a grandchild session (child of child).  Verify that its place
# in the grand scheme of things is secure.

my $grand    = bless [ ], "POE::Session";
my $grand_id = $poe_kernel->_data_sid_allocate();
$grand->_set_id($grand_id);

$poe_kernel->_data_ses_allocate(
  $grand,      # session
  $grand_id,   # sid
  $child_sid,  # parent
);

my $base_grand_refcount = $poe_kernel->_data_ses_refcount($grand_id);

{ my @children = $poe_kernel->_data_ses_get_children($child_sid);
  is_deeply(
    \@children, [ $grand ],
    "child has only the grandchild session"
  );

  is(
    $poe_kernel->_data_ses_refcount($child_sid), $base_child_refcount + 1,
    "child refcount incremented by the grandchild"
  );

  my $parent = $poe_kernel->_data_ses_get_parent($grand_id);
  is($parent, $child, "grandchild's parent is child");

  ok(
    $poe_kernel->_data_ses_is_child($child_sid, $grand_id),
    "grandchild is child of child"
  );

  is($poe_kernel->_data_ses_count(), 3, "three sessions now");
}

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  is_deeply(
    \@children, [ $child ],
    "POE::Kernel children untouched by grandchild"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount + 1,
    "POE::Kernel's refcount untouched by grandchild"
  );
}

# Create a great-grandchild session (child of grandchild).  Verify
# that its place in the grand scheme of things is secure.

my $great    = bless [ ], "POE::Session";
my $great_id = $poe_kernel->_data_sid_allocate();
$great->_set_id($great_id);

$poe_kernel->_data_ses_allocate(
  $great,      # session
  $great_id,   # sid
  $grand_id,   # parent
);

my $base_great_refcount = $poe_kernel->_data_ses_refcount($great_id);

{ my @children = $poe_kernel->_data_ses_get_children($grand_id);
  is_deeply(
    \@children, [ $great ],
    "grandchild has only the great-grandchild session"
  );

  is(
    $poe_kernel->_data_ses_refcount($grand_id), $base_grand_refcount + 1,
    "grandchild refcount incremented by the great-grandchild"
  );

  my $parent = $poe_kernel->_data_ses_get_parent($great_id);
  is($parent, $grand, "great-grandchild's parent is grandchild");

  ok(
    $poe_kernel->_data_ses_is_child($child_sid, $grand_id),
    "great-grandchild is child of grandchild"
  );
}

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  is_deeply(
    \@children, [ $child ],
    "POE::Kernel children untouched by great-grandchild"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount + 1,
    "POE::Kernel's refcount untouched by great-grandchild"
  );
}

{ my @children = $poe_kernel->_data_ses_get_children($child_sid);
  is_deeply(
    \@children, [ $grand ],
    "child children untouched by great-grandchild"
  );

  is(
    $poe_kernel->_data_ses_refcount($child_sid), $base_child_refcount + 1,
    "child's refcount untouched by great-grandchild"
  );
}

{ my @children = $poe_kernel->_data_ses_get_children($great_id);
  is(scalar(@children), 0, "no great-great-grandchildren");
}

# Move the grandchild to just under POE::Kernel.  This makes child and
# grandchild siblings.

$poe_kernel->_data_ses_move_child($grand_id, $poe_kernel->ID);

is(
  $poe_kernel->_data_ses_get_parent($child_sid), $poe_kernel,
  "child's parent is POE::Kernel"
);

is(
  $poe_kernel->_data_ses_get_parent($grand_id), $poe_kernel,
  "grandchild's parent is POE::Kernel"
);

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  my %kids = map {($_=>1)} @children;

  ok(exists($kids{$child}), "POE::Kernel owns child");
  ok(exists $kids{$grand}, "POE::Kernel owns grandchild");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount + 2,
    "POE::Kernel refcount increased since inheriting grandchild"
  );
}

{ my @children = $poe_kernel->_data_ses_get_children($child_sid);
  is_deeply( \@children, [ ], "child has no children" );

  is(
    $poe_kernel->_data_ses_refcount($child_sid), $base_child_refcount,
    "child's refcount decreased since losing grandchild"
  );
}

# Free the childless child.  Make sure POE::Kernel/child data
# structures cross-reference.

$poe_kernel->_data_ses_free($child_sid);

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  is_deeply(
    \@children, [ $grand ],
    "POE::Kernel only has grandchild now"
  );

  my $parent = $poe_kernel->_data_ses_get_parent($grand_id);
  is($parent, $poe_kernel, "grandchild's parent is POE::Kernel");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount + 1,
    "POE::Kernel's refcount decremented on child loss"
  );

  eval { my $parent = $poe_kernel->_data_ses_get_parent($child_sid) };
  ok(
    $@ && $@ =~ /retrieving parent of a nonexistent session/,
    "can't get parent of nonexistent session"
  );

  eval { my $parent = $poe_kernel->_data_ses_get_children($child_sid) };
  ok(
    $@ && $@ =~ /retrieving children of a nonexistent session/,
    "can't get children of nonexistent session"
  );

  eval { my $parent = $poe_kernel->_data_ses_is_child($child_sid, $child_sid) };
  ok(
    $@ && $@ =~ /testing is-child of a nonexistent parent session/,
    "can't test is-child of nonexistent session"
  );
}

# Stop the grandchild.  The great-grandchild will be inherited by
# POE::Kernel after this.

$poe_kernel->_data_ses_stop($grand_id);

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  is_deeply(
    \@children, [ $great ],
    "POE::Kernel only has great-grandchild now"
  );

  my $parent = $poe_kernel->_data_ses_get_parent($great_id);
  is($parent, $poe_kernel, "great-grandchild's parent is POE::Kernel");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount + 1,
    "POE::Kernel's refcount conserved"
  );
}

# Try garbage collection on a session that can use stopping.

$poe_kernel->_data_ses_collect_garbage($great_id);

{ my @children = $poe_kernel->_data_ses_get_children($poe_kernel->ID);
  is_deeply(
    \@children, [ ],
    "POE::Kernel has no children anymore"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_kernel_refcount,
    "POE::Kernel's refcount back to basics"
  );
}

# Test traps for dealing with nonexistent sessions.

eval { $poe_kernel->_data_ses_refcount_inc("nonexistent") };
ok(
  $@ && $@ =~ /incrementing refcount for nonexistent session/,
  "can't increment refcount for nonexistent session"
);

eval { $poe_kernel->_data_ses_refcount_dec("nonexistent") };
ok(
  $@ && $@ =~ /decrementing refcount of a nonexistent session/,
  "can't decrement refcount for nonexistent session"
);

eval { $poe_kernel->_data_ses_stop("nonexistent") };
ok(
  $@ && $@ =~ /stopping a nonexistent session/,
  "can't stop a nonexistent session"
);

# Attempt to allocate a session for a nonexistent parent.

my $bogus     = bless [ ], "POE::Session";
my $bogus_sid = $poe_kernel->_data_sid_allocate();
$bogus->_set_id($bogus_sid);

eval {
  $poe_kernel->_data_ses_allocate(
    $bogus,        # session
    $bogus_sid,    # sid
    "nonexistent", # parent
  )
};
ok(
  $@ && $@ =~ /parent session nonexistent does not exist/,
  "can't allocate a session for an unknown parent"
);

# Attempt to allocate a session that already exists.

eval {
  $poe_kernel->_data_ses_allocate(
    $poe_kernel,     # session
    $poe_kernel->ID, # sid
    $poe_kernel->ID, # parent
  )
};
ok(
  $@ && $@ =~ /session .*? is already allocated/,
  "can't allocate a session that's already allocated"
);

# Attempt to move nonexistent sessions around.

eval { $poe_kernel->_data_ses_move_child("nonexistent", $poe_kernel->ID) };
ok(
  $@ && $@ =~ /moving nonexistent child to another parent/,
  "can't move nonexistent child to another parent"
);

eval { $poe_kernel->_data_ses_move_child($poe_kernel->ID, "nonexistent") };
ok(
  $@ && $@ =~ /moving child to a nonexistent parent/,
  "can't move a session to a nonexistent parent"
);

# Free the last session, and finalize the subsystem.  Freeing it is
# necessary because the original refcount includes some events that
# would otherwise count as leakage during finalization.

$poe_kernel->_data_ses_stop($poe_kernel->ID);

ok($poe_kernel->_data_ses_finalize(), "finalized POE::Resource::Sessions");

1;
