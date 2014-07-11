#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab
use warnings;
use strict;

use Test::More tests => 1;

use_ok('POE');

eval "use POE::Test::Loops";
$POE::Test::Loops::VERSION = "doesn't seem to be installed" if $@;

# idea from Test::Harness, thanks!
diag(
  "Testing POE ", ($POE::VERSION || -1), ", ",
  "POE::Test::Loops ", ($POE::Test::Loops::VERSION || -1), ", ",
  "Perl $], ",
  "$^X on $^O"
);

# Benchmark the device under test.

my $done = 0;
my $x    = 0;
$SIG{ALRM} = sub { diag "pogomips: $x"; $done = 1; };
alarm(1);
++$x until $done;
