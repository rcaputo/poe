#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

BEGIN { use_ok("POE::Filter") }

eval { my $x = POE::Filter->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Filter"
);

exit 0;
