#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./lib ../lib . ..);
use TestSetup;

use POE;

test_setup(14);

# Set an alias and verify that it can be retrieved.  Also verify the
# loggable version of it.

{ $poe_kernel->_data_alias_add($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  ok_if(1, $session == $poe_kernel);

  # Should be 3: One for the signal poller timer, one for the virtual
  # POE::Kernel session, and one for the new alias.
  ok_if(2, $poe_kernel->_data_ses_refcount($poe_kernel) == 3);

  my $loggable = $poe_kernel->_data_alias_loggable($poe_kernel);
  my $kernel_id = $poe_kernel->ID;
  ok_if(3, $loggable =~ /^session \Q$kernel_id\E \(alias-1\)$/);
}

# Remove the alias and verify that it is gone.

{ $poe_kernel->_data_alias_remove($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  ok_unless(4, defined $session);

  # Should be 2.  See the rationale above.
  ok_if(5, $poe_kernel->_data_ses_refcount($poe_kernel) == 2);
}

# Set multiple aliases and verify that they exist.

my @multi_aliases = qw( alias-1 alias-2 alias-3 );
{ foreach (@multi_aliases) {
    $poe_kernel->_data_alias_add($poe_kernel, $_);
  }

  ok_if(6, $poe_kernel->_data_alias_count_ses($poe_kernel) == @multi_aliases);

  ok_if(7, $poe_kernel->_data_ses_refcount($poe_kernel) == 5);

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);

  my $lists_are_equal = @multi_aliases == @retrieved;
  for (0..$#retrieved) {
    next if $multi_aliases[$_] eq $retrieved[$_];
    $lists_are_equal = 0;
    last
  }

  ok_if(8, $lists_are_equal);
}

# Clear all the aliases for the session, and make sure they're gone.

{ $poe_kernel->_data_alias_clear_session($poe_kernel);

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);
  ok_unless(9, @retrieved);

  # See previous rationale for the number 2.
  ok_if(10, $poe_kernel->_data_ses_refcount($poe_kernel) == 2);
}

# Some tests and testless instrumentation on nonexistent sessions.

{ ok_unless(11, $poe_kernel->_data_alias_count_ses("nothing"));

  # Instrument some code.
  $poe_kernel->_data_alias_clear_session("nothing");

  ok_unless(12, defined $poe_kernel->_data_alias_resolve("nothing"));
}

# At this point, everything should be clean.
{ ok_if(13, $poe_kernel->_data_alias_count() == 0);
  ok_if(14, $poe_kernel->_data_alias_xref_count() == 0);
}

# This is unnecessary; we've empirically tested whether the subsystem
# has shut down cleanly.  Do it anyway to instrument some code.
$poe_kernel->_data_alias_finalize();

results();
exit 0;
