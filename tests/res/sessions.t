#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./mylib ../mylib . ..);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

test_setup(55);

# Gather the parent session's reference count.  We use this as a
# baseline for the other tests.

my $base_parent_refcount = $poe_kernel->_data_ses_refcount($poe_kernel);

# Allocate a test session.  This isn't REALLY a session, but we're
# treating it as such.

my $child = bless [ ], "POE::Session";
my $child_sid = $poe_kernel->_data_sid_allocate();

$poe_kernel->_data_ses_allocate(
  $child,      # session
  $child_sid,  # sid
  $poe_kernel, # parent
);

# Ensure that the SID was set.
ok_if(1, $poe_kernel->_data_sid_resolve($child_sid) == $child);

# Ensure that the session reference may be resolved from its
# stringified version.
ok_if(2, $poe_kernel->_data_ses_resolve("$child") == $child);

# Ensure that a session's ID may be resolved from its reference.
ok_if(3, $poe_kernel->_data_ses_resolve_to_id($child) == $child_sid);

# Also test the resolve functions against nonexistent sessions.
ok_unless(4, defined $poe_kernel->_data_ses_resolve("nonexistent"));
ok_unless(5, defined $poe_kernel->_data_ses_resolve_to_id("nonexistent"));

# Ensure that the session is a child of the supplied parent.
{ my @kernel_kids = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(6, @kernel_kids == 1);
  ok_if(7, $kernel_kids[0] == $child);
}

# Ensure that the session's parent is the kernel.
{ my $parent = $poe_kernel->_data_ses_get_parent($child);
  ok_if(8, $parent == $poe_kernel);
}

# Ensure that the parent's reference count has increased by 1.
ok_if(
  9,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 1
);

# Get a baseline child refcount for testing.
my $base_child_refcount = $poe_kernel->_data_ses_refcount($child);

# Add a grandchild (child of $session).
my $grandchild = bless [ ], "POE::Session";
my $grandchild_sid = $poe_kernel->_data_sid_allocate();

$poe_kernel->_data_ses_allocate(
  $grandchild,      # session
  $grandchild_sid,  # sid
  $child,           # parent
);

# Ensure that the Kernel (the grandparent) was not touched by the
# addition of the grandchild session.
{ my @kernel_kids = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(10, @kernel_kids == 1);
  ok_if(11, $kernel_kids[0] == $child);
}

ok_if(
  12,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 1
);

# Ensure that the child WAS touched by the addition of the grandchild.
{ my @child_kids = $poe_kernel->_data_ses_get_children($child);
  ok_if(13, @child_kids == 1);
  ok_if(14, $child_kids[0] == $grandchild);
}

# Ensure that the grandchild's parent is the child.
{ my $parent = $poe_kernel->_data_ses_get_parent($grandchild);
  ok_if(15, $parent == $child);
}

# Ensure that the grandchild's reference count has incremented.
ok_if(
  16,
  $poe_kernel->_data_ses_refcount($child) == $base_child_refcount + 1
);

# Make sure the grandchild has no children.
{ my @grandchild_kids = $poe_kernel->_data_ses_get_children($grandchild);
  ok_if(17, @grandchild_kids == 0);
}

# Now make sure we have the right number of sessions.  Parent, child,
# and grandchild make three.
ok_if(18, $poe_kernel->_data_ses_count() == 3);

# Make sure POE::Resource::Session understands the parent/child
# relationships here.
ok_if(19, $poe_kernel->_data_ses_is_child($poe_kernel, $child));
ok_if(20, $poe_kernel->_data_ses_is_child($child, $grandchild));
ok_unless(21, $poe_kernel->_data_ses_is_child($child, $poe_kernel));
ok_unless(22, $poe_kernel->_data_ses_is_child($grandchild, $child));

# Make sure POE::Resource::Session understands which sessions exist
# and which don't.
ok_if(23, $poe_kernel->_data_ses_exists($poe_kernel));
ok_if(24, $poe_kernel->_data_ses_exists($child));
ok_if(25, $poe_kernel->_data_ses_exists($grandchild));
ok_unless(26, $poe_kernel->_data_ses_exists("nonexistent"));

# Get a baseline grandchild refcount for testing.
my $base_grandchild_refcount = $poe_kernel->_data_ses_refcount($grandchild);

# Add a great-grandchild (child of $session).
my $great = bless [ ], "POE::Session";
my $great_id = $poe_kernel->_data_sid_allocate();

$poe_kernel->_data_ses_allocate(
  $great,      # session
  $great_id,   # sid
  $grandchild, # parent
);

# Ensure that the Kernel (the grandparent) was not touched by the
# addition of the grandchild session.
{ my @kernel_kids = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(27, @kernel_kids == 1);
  ok_if(28, $kernel_kids[0] == $child);
}

ok_if(
  29,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 1
);

# Ensure that the grandchild WAS touched by the addition of ITS child.
{ my @grandchild_kids = $poe_kernel->_data_ses_get_children($grandchild);
  ok_if(30, @grandchild_kids == 1);
  ok_if(31, $grandchild_kids[0] == $great);
}

# Ensure that the great-grandchild's parent is the child.
{ my $parent = $poe_kernel->_data_ses_get_parent($great);
  ok_if(32, $grandchild == $parent);
}

# Ensure that the grandchild's reference count has incremented.
ok_if(
  33,
  $poe_kernel->_data_ses_refcount($child) == $base_grandchild_refcount + 1
);

# Make sure the great-grandchild has no children.
{ my @great_kids = $poe_kernel->_data_ses_get_children($great);
  ok_if(34, @great_kids == 0);
}

### Now we have a parent, its child, a grandchild, and a
### great-grandchild, all in a row.

# Move the grandchild to be a child of the parent.  Now we have a
# parent and two children.  One of the children has its own child.
$poe_kernel->_data_ses_move_child($grandchild, $poe_kernel);

# Verify that the "parent" has two children now: "child", and what was
# originally the "grandchild".  Verify that the "grandchild"'s parent
# is now the "parent".
{ my @parent_children = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(35, @parent_children == 2);
  my %kids = map {($_=>1)} @parent_children;
  ok_if(36, exists $kids{$child});
  ok_if(37, exists $kids{$grandchild});
  ok_if(38, $poe_kernel->_data_ses_get_parent($child) == $poe_kernel);
  ok_if(39, $poe_kernel->_data_ses_get_parent($grandchild) == $poe_kernel);
}

# Verify that the parent's reference count increased as it gained a
# new child.
ok_if(
  40,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 2
);

# Verify that the child's reference count decreased as it lost its
# child.
ok_if(
  41,
  $poe_kernel->_data_ses_refcount($child) == $base_child_refcount
);

# Free the child session.  Make sure things add up.
$poe_kernel->_data_ses_free($child);

# Parent session has one fewer children.
{ my @kernel_kids = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(42, @kernel_kids == 1);
  ok_if(43, $kernel_kids[0] == $grandchild);
}

# Parent's refcount is one less than before.
ok_if(
  44,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 1
);

# Free the grandchild session.  Make sure things add up.
$poe_kernel->_data_ses_free($grandchild);

# Parent session has the same number of children, but its child is now
# what used to be the great-grandchild.
{ my @kernel_kids = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(45, @kernel_kids == 1);
  ok_if(46, $kernel_kids[0] == $great);
}

# Parent's refcount is unchanged.
ok_if(
  47,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 1
);

# Grandchild's parent is now the "parent".
ok_if(48, $poe_kernel->_data_ses_get_parent($great) == $poe_kernel);

# Free the great-grandchild session.  Make sure things add up.
$poe_kernel->_data_ses_free($great);

# Kernel (parent) has no children now.
{ my @kernel_kids = $poe_kernel->_data_ses_get_children($poe_kernel);
  ok_if(49, @kernel_kids == 0);
}

# Parent's refcount is back to the beginning.
ok_if(
  50,
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_parent_refcount + 0
);

# Finally, free the parent thingy.  -><- I don't know why this is
# necessary, which indicates a potential problem somewhere.
$poe_kernel->_data_ses_free($poe_kernel);
ok_if(51, $poe_kernel->_data_ses_count() == 0);

# TODO _data_ses_stop() is not tested.  We will need to run an event
# loop with proper sessions to do so.  I am leaving it for later.
ok(52, "skipped: _data_ses_stop should be tested properly");

# TODO _data_ses_collect_garbage() is not tested.  We will need to run
# an event loop with proper sessions to do so.  I am leaving it for
# later.
ok(53, "skipped: _data_ses_collect_garbage should be tested properly");

# TODO _data_ses_free() is not tested properly.  To do this properly,
# we need to allocate one of every other resource and ensure they are
# all cleared when the session's forcibly freed.
ok(54, "skipped: _data_ses_free should be tested properly");

# Final test to be sure everything ends on a clean note.
ok_if(55, $poe_kernel->_data_ses_finalize());

results();
exit 0;
