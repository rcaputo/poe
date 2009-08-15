#!/usr/bin/perl -w

use strict;

use Test::More tests => 1;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
BEGIN { use_ok("POE", "Loop::Select") }
