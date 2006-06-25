#!/usr/bin/perl -w
# $Id: /branches/poe-tests/tests/30_loops/00_base/wheel_tail.pm 10644 2006-05-29T17:02:47.597324Z bsmith  $

# Exercises Wheel::Curses

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More;
use POE;

BEGIN {
  eval { require Curses };
  if ($@) {
    plan skip_all => 'Curses not available';
  }

  plan tests => 2;
  use_ok('POE::Wheel::Curses');
}

sub DEBUG () { 0 }


### main loop

POE::Kernel->run();

pass("run() returned successfully");

1;
