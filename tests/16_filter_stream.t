#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Stream without the rest of POE.

use strict;
use lib qw(./lib ../lib);

sub POE::Kernel::TRACE_DEFAULT () { 1 } # not needed though
use POE::Filter::Stream;

use TestSetup;
&test_setup(10);

# Self-congratulatory backpatting.
print "ok 1\n";

# Test stream filter in fixed-length mode.
my $filter = new POE::Filter::Stream;
my @test_fodder = qw(a bc def ghij klmno);

my $received = $filter->get( \@test_fodder );
if (@$received == 1) {
  print "ok 2\n";
  print 'not ' unless $received->[0] eq 'abcdefghijklmno';
  print "ok 3\n";
}
else {
  print "not ok 2\n";
  print "not ok 3\n";
}

my $sent = $filter->put( \@test_fodder );
if (@$sent == @test_fodder) {
  print "ok 4\n";
  print 'not ' unless $sent->[0] eq $test_fodder[0];
  print "ok 5\n";
  print 'not ' unless $sent->[1] eq $test_fodder[1];
  print "ok 6\n";
  print 'not ' unless $sent->[2] eq $test_fodder[2];
  print "ok 7\n";
  print 'not ' unless $sent->[3] eq $test_fodder[3];
  print "ok 8\n";
  print 'not ' unless $sent->[4] eq $test_fodder[4];
  print "ok 9\n";
}
else {
  print "not ok 4\n";
  print "not ok 5\n";
  print "not ok 6\n";
  print "not ok 7\n";
  print "not ok 8\n";
  print "not ok 9\n";
}

print "ok 10\n";

exit;
