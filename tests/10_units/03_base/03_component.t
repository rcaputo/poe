#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

BEGIN { use_ok("POE::Component") }

eval { my $x = POE::Component->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Component"
);

exit 0;
