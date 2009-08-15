use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 15;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok("POE") }

# Set an alias and verify that it can be retrieved.  Also verify the
# loggable version of it.

{ $poe_kernel->_data_alias_add($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  ok($session == $poe_kernel, "alias resolves to original reference");

  # Should be 3: One for the performance timer, one for the virtual
  # POE::Kernel session, and one for the new alias.
  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 3,
    "session reference count is to be expected"
  );

  my $loggable = $poe_kernel->_data_alias_loggable($poe_kernel);
  my $kernel_id = $poe_kernel->ID;
  ok(
    $loggable =~ /^session \Q$kernel_id\E \(alias-1\)$/,
    "loggable version of session is valid"
  );
}

# Remove the alias and verify that it is gone.

{ $poe_kernel->_data_alias_remove($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  ok(!defined($session), "removed alias does not resolve");

  # Should be 2.  See the rationale above.
  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 2,
    "session reference count reduced correctly"
  );
}

# Set multiple aliases and verify that they exist.

my @multi_aliases = qw( alias-1 alias-2 alias-3 );
{ foreach (@multi_aliases) {
    $poe_kernel->_data_alias_add($poe_kernel, $_);
  }

  ok(
    $poe_kernel->_data_alias_count_ses($poe_kernel) == @multi_aliases,
    "correct number of aliases were recorded"
  );

  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 5,
    "correct number of references were recorded"
  );

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);
  ok(
    eq_array(\@retrieved, \@multi_aliases),
    "the aliases were retrieved correctly"
  );
}

# Clear all the aliases for the session, and make sure they're gone.

{ $poe_kernel->_data_alias_clear_session($poe_kernel);

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);
  ok(!@retrieved, "aliases were cleared successfully");

  # See previous rationale for test 2.
  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == 2,
    "proper number of references after alias clear"
  );
}

# Some tests and testless instrumentation on nonexistent sessions.

{ ok(
    $poe_kernel->_data_alias_count_ses("nothing") == 0,
    "unknown session has no aliases"
  );

  $poe_kernel->_data_alias_clear_session("nothing");
  ok(
    !defined($poe_kernel->_data_alias_resolve("nothing")),
    "unused alias does not resolve to anything"
  );

  eval { $poe_kernel->_data_alias_loggable("moo") };
  ok($@, "trap while attempting to make loggable version of bogus session");
}

# Finalize the subsystem.  Returns true if everything shut down
# cleanly, or false if it didn't.
ok(
  $poe_kernel->_data_alias_finalize(),
  "POE::Resource::Aliases finalizes cleanly"
);

1;
