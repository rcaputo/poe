#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

BEGIN { use_ok("POE::Resource") }

eval { my $x = POE::Resource->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Resource"
);

exit 0;
