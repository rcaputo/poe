#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

BEGIN { use_ok("POE::Loop") }

eval { my $x = POE::Loop->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Loop"
);

exit 0;
