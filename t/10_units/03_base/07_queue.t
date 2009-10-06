#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 2;

BEGIN { use_ok("POE::Queue") }

eval { my $x = POE::Queue->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Queue"
);

exit 0;
