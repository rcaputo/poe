#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 2;

BEGIN { use_ok("POE::Driver") }

eval { my $x = POE::Driver->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Driver"
);

exit 0;
