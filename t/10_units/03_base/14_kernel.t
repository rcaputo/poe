#!/usr/bin/perl -w

# This file contains tests for the _public_ POE::Kernel interface

use strict;

use Test::More tests => 6;
use vars qw($poe_kernel);

BEGIN { use_ok("POE::Kernel"); }

# Start with errors.

eval { POE::Kernel->import( 'foo' ) };
ok(
  $@ && $@ =~ /expects its arguments/,
  "fails without a hash ref"
);

eval { POE::Kernel->import( { foo => "bar" } ) };
ok(
  $@ && $@ =~ /import arguments/,
  "fails with bogus hash ref"
);

eval { POE::Kernel->import( { loop => "Loop::Select" } ) };
ok(
  !$@,
  "specifying which loop to load works"
);

ok( defined($poe_kernel), "POE::Kernel exports $poe_kernel" );
ok( UNIVERSAL::isa($poe_kernel, "POE::Kernel"), "  which contains a kernel" );

exit 0;
