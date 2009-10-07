#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab
use warnings;
use strict;

use Test::More tests => 2;
use_ok('POE');
use_ok('POE::Test::Loops');

# idea from Test::Harness, thanks!
diag(
  "Testing POE $POE::VERSION, ",
  "POE::Test::Loops $POE::Test::Loops::VERSION, ",
  "Perl $], ",
  "$^X on $^O"
);
