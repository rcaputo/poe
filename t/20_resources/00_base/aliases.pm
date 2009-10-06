# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 15;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

sub POE::Kernel::USE_SIGCHLD () { 0 }

BEGIN { use_ok("POE") }

# Base reference count = Statistics timer event.
my $base_refcount = 0;
$base_refcount += 2 if POE::Kernel::TRACE_STATISTICS;

# Set an alias and verify that it can be retrieved.  Also verify the
# loggable version of it.

{ $poe_kernel->_data_alias_add($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  is($session, $poe_kernel, "alias resolves to original reference");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel), $base_refcount + 1,
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
  is(
    $poe_kernel->_data_ses_refcount($poe_kernel), $base_refcount,
    "session reference count reduced correctly"
  );
}

# Set multiple aliases and verify that they exist.

my @multi_aliases = qw( alias-1 alias-2 alias-3 );
{ foreach (@multi_aliases) {
    $poe_kernel->_data_alias_add($poe_kernel, $_);
  }

  is(
    $poe_kernel->_data_alias_count_ses($poe_kernel), @multi_aliases,
    "correct number of aliases were recorded"
  );

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel), $base_refcount + 3,
    "correct number of references were recorded"
  );

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);
  is_deeply(
    \@retrieved, \@multi_aliases,
    "the aliases were retrieved correctly"
  );
}

# Clear all the aliases for the session, and make sure they're gone.

{ $poe_kernel->_data_alias_clear_session($poe_kernel);

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);
  is(scalar(@retrieved), 0, "aliases were cleared successfully");

  is(
    $poe_kernel->_data_ses_refcount($poe_kernel), $base_refcount,
    "proper number of references after alias clear"
  );
}

# Some tests and testless instrumentation on nonexistent sessions.

{ is(
    $poe_kernel->_data_alias_count_ses("nothing"), 0,
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
