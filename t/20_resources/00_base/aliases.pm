# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 14;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

sub POE::Kernel::USE_SIGCHLD () { 0 }

BEGIN { use_ok("POE") }

# Base reference count.
my $base_refcount = 0;

my $kr_aliases = $poe_kernel->[POE::Kernel::KR_ALIASES()];

# Set an alias and verify that it can be retrieved.  Also verify the
# loggable version of it.

{ $kr_aliases->add($poe_kernel, "alias-1");
  my $session = $kr_aliases->resolve("alias-1");
  is($session, $poe_kernel, "alias resolves to original reference");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 1,
    "session reference count is to be expected"
  );

  my $kernel_id = $poe_kernel->ID;
  my $loggable = $kr_aliases->loggable_sid($kernel_id);
  ok(
    $loggable =~ /^session \Q$kernel_id\E \(alias-1\)$/,
    "loggable version of session is valid"
  );
}

# Remove the alias and verify that it is gone.

{ $kr_aliases->remove($poe_kernel, "alias-1");
  my $session = $kr_aliases->resolve("alias-1");
  ok(!defined($session), "removed alias does not resolve");

  # Should be 2.  See the rationale above.
  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount,
    "session reference count reduced correctly"
  );
}

# Set multiple aliases and verify that they exist.

my @multi_aliases = qw( alias-1 alias-2 alias-3 );
{ foreach (@multi_aliases) {
    $kr_aliases->add($poe_kernel, $_);
  }

  is(
    $kr_aliases->count_for_session($poe_kernel->ID), @multi_aliases,
    "correct number of aliases were recorded"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount + 3,
    "correct number of references were recorded"
  );

  my @retrieved = $kr_aliases->get_sid_aliases($poe_kernel->ID);
  is_deeply(
    \@retrieved, \@multi_aliases,
    "the aliases were retrieved correctly"
  );
}

# Clear all the aliases for the session, and make sure they're gone.

{ $kr_aliases->clear_session($poe_kernel->ID);

  my @retrieved = $kr_aliases->get_sid_aliases($poe_kernel->ID);
  is(scalar(@retrieved), 0, "aliases were cleared successfully");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel->ID), $base_refcount,
    "proper number of references after alias clear"
  );
}

# Some tests and testless instrumentation on nonexistent sessions.

{ is(
    $kr_aliases->count_for_session("nothing"), 0,
    "unknown session has no aliases"
  );

  $kr_aliases->clear_session("nothing");
  ok(
    !defined($kr_aliases->resolve("nothing")),
    "unused alias does not resolve to anything"
  );
}

# Finalize the subsystem.  Returns true if everything shut down
# cleanly, or false if it didn't.
ok(
  $kr_aliases->finalize(),
  "POE::Resource::Aliases finalizes cleanly"
);

1;
