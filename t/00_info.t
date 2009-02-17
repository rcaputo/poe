#!/usr/bin/perl
use strict; use warnings;

use Test::More tests => 1;
use_ok( 'POE' );

# idea from Test::Harness, thanks!
diag("Testing POE $POE::VERSION, Perl $], $^X on $^O");

