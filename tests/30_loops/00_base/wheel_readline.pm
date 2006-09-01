#!/usr/bin/perl -w
# $Id: /branches/poe-tests/tests/30_loops/00_base/wheel_tail.pm 10644 2006-05-29T17:02:47.597324Z bsmith  $

# Exercises Wheel::ReadLine

use strict;
use warnings;
use lib qw(./mylib ../mylib);

#sub POE::Kernel::ASSERT_DEFAULT () { 1 }
#sub POE::Kernel::TRACE_DEFAULT  () { 1 }
#sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More;

BEGIN {
  my $error;
  if ($^O eq "MSWin32") {
    $error = "$^O cannot multiplex terminals";
  }
  elsif (!-t STDIN ) {
    $error = "not running in a terminal";
  }

  if ($error) {
    plan skip_all => $error;
    CORE::exit();
  }

  plan tests => 2;
}

use POE;

use_ok('POE::Wheel::ReadLine');

sub DEBUG () { 0 }

### main loop

POE::Kernel->run();

pass("run() returned successfully");

1;
