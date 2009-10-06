#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab
use warnings;
use strict;

use Test::More tests => 1;
use_ok( 'POE' );

# idea from Test::Harness, thanks!
diag("Testing POE $POE::VERSION, Perl $], $^X on $^O");

