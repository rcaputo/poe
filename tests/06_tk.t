#!/usr/bin/perl -w
# $Id$

# Tests FIFO, alarm, select and Tk postback events using Tk's event
# loop.

use strict;
use lib qw(./lib ../lib);
use TestSetup qw(99);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

# Skip if Tk isn't here.
BEGIN {
  eval 'use Tk';
  unless (exists $INC{'Tk.pm'}) {
    for (my $test=1; $test <= 1; $test++) {
      print "skip $test # no Tk support\n";
    }
  }
}

use POE;

# Congratulate ourselves for getting this far.
print "ok 1\n";

$poe_kernel->run();

# Congratulate ourselves on a job completed, regardless of how well it
# was done.
print "ok N\n";

exit;
