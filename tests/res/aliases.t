#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./lib ../lib . ..);
use TestSetup;

use POE;

test_setup(8);

# Set an alias and verify that it can be retrieved.  Also verify the
# loggable version of it.

{ $poe_kernel->_data_alias_add($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  ok_if(1, $session == $poe_kernel);

  my $loggable = $poe_kernel->_data_alias_loggable($poe_kernel);
  my $kernel_id = $poe_kernel->ID;
  ok_if(2, $loggable =~ /^session \Q$kernel_id\E \(alias-1\)$/);
}

# Remove the alias and verify that it is gone.

{ $poe_kernel->_data_alias_remove($poe_kernel, "alias-1");
  my $session = $poe_kernel->_data_alias_resolve("alias-1");
  ok_unless(3, defined $session);
}

# Set multiple aliases and verify that they exist.

my @multi_aliases = qw( alias-1 alias-2 alias-3 );
{ foreach (@multi_aliases) {
    $poe_kernel->_data_alias_add($poe_kernel, $_);
  }

  ok_if(4, $poe_kernel->_data_alias_count_ses($poe_kernel) == @multi_aliases);

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);

  my $lists_are_equal = @multi_aliases == @retrieved;
  for (0..$#retrieved) {
    next if $multi_aliases[$_] eq $retrieved[$_];
    $lists_are_equal = 0;
    last
  }

  ok_if(5, $lists_are_equal);
}

# Clear all the aliases for the session, and make sure they're gone.

{ $poe_kernel->_data_alias_clear_session($poe_kernel);

  my @retrieved = $poe_kernel->_data_alias_list($poe_kernel);
  ok_unless(6, @retrieved);
}

# Some tests and testless instrumentation on nonexistent sessions.

{ ok_unless(7, $poe_kernel->_data_alias_count_ses("nothing"));

  # Instrument some code.
  $poe_kernel->_data_alias_clear_session("nothing");

  ok_unless(8, defined $poe_kernel->_data_alias_resolve("nothing"));
}

$poe_kernel->_data_alias_finalize();

results();
exit 0;
