#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;

BEGIN { eval "use POE::Kernel"; ok(!$@, "kernel loads"); }

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

exit 0;
