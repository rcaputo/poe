#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Block without the rest of POE.  Suddenly things
# are looking a lot easier.

use strict;
use lib qw(./lib ../lib .. .);

use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
BEGIN { open STDERR, ">./test-output.err" or die $!; }

use POE::Filter::Block;

test_setup(27);

# Self-congratulatory backpatting.
print "ok 1\n";

# Test block filter in fixed-length mode.
{ my $filter = new POE::Filter::Block( BlockSize => 4 );
  my $raw = $filter->put( [ '12345678' ] );
  my $cooked = $filter->get( $raw );
  if (@$cooked == 2) {
    print "ok 2\n";
    print 'not ' unless length($cooked->[0]) == 4;
    print "ok 3\n";
    print 'not ' unless length($cooked->[1]) == 4;
    print "ok 4\n";
  }
  else {
    print "not ok 2\n";
    print "not ok 3\n";
    print "not ok 4\n";
  }
  $raw = $filter->put( $cooked );
  if (@$raw == 1) {
    print "ok 5\n";
    print 'not ' unless length($raw->[0]) == 8;
    print "ok 6\n";
  }
  else {
    print "not ok 5\n";
    print "not ok 6\n";
  }
}

# Test block filter with get_one() functions.
{ my $filter = new POE::Filter::Block( BlockSize => 4 );
  my $raw = $filter->put( [ '12345678' ] );
  $filter->get_one_start( $raw );
  my $cooked = $filter->get_one();
  if (@$cooked == 1) {
    print "ok 7\n";
    print 'not ' unless length($cooked->[0]) == 4;
    print "ok 8\n";
  }
  else {
    print "not ok 7\n";
    print "not ok 8\n";
  }
  $raw = $filter->put( $cooked );
  if (@$raw == 1) {
    print "ok 9\n";
    print 'not ' unless length($raw->[0]) == 4;
    print "ok 10\n";
  }
  else {
    print "not ok 9\n";
    print "not ok 10\n";
  }
}

# Test block filter in variable-length mode.
{ my $filter = new POE::Filter::Block( );
  my $raw = "1\0a2\0bc3\0def4\0ghij";
  my $cooked = $filter->get( [ $raw ] );
  if (@$cooked == 4) {
    print "ok 11\n";
    print 'not ' unless $cooked->[0] eq 'a';
    print "ok 12\n";
    print 'not ' unless $cooked->[1] eq 'bc';
    print "ok 13\n";
    print 'not ' unless $cooked->[2] eq 'def';
    print "ok 14\n";
    print 'not ' unless $cooked->[3] eq 'ghij';
    print "ok 15\n";

    $cooked = $filter->get( [ "1" ] );
    print 'not ' if @$cooked;
    print "ok 16\n";

    $cooked = $filter->get( [ "0" ] );
    print 'not ' if @$cooked;
    print "ok 17\n";

    $cooked = $filter->get( [ "\0" ] );
    print 'not ' if @$cooked;
    print "ok 18\n";

    $cooked = $filter->get( [ "klmno" ] );
    print 'not ' if @$cooked;
    print "ok 19\n";

    $cooked = $filter->get( [ "pqrst" ] );
    if (@$cooked == 1) {
      print "ok 20\n";
      print 'not ' unless $cooked->[0] eq 'klmnopqrst';
      print "ok 21\n";
    }
    else {
      print "not ok 20\n";
      print "not ok 21\n";
    }
  }
  else {
    print "not ok 11\n";
    print "not ok 12\n";
    print "not ok 13\n";
    print "not ok 14\n";
    print "not ok 15\n";
    print "not ok 16\n";
    print "not ok 17\n";
    print "not ok 18\n";
    print "not ok 19\n";
    print "not ok 20\n";
    print "not ok 21\n";
  }

  my $raw_two = $filter->put( [ qw(a bc def ghij) ] );
  if (@$raw_two == 4) {
    print "ok 22\n";
    print 'not ' unless $raw_two->[0] eq "1\0a";
    print "ok 23\n";
    print 'not ' unless $raw_two->[1] eq "2\0bc";
    print "ok 24\n";
    print 'not ' unless $raw_two->[2] eq "3\0def";
    print "ok 25\n";
    print 'not ' unless $raw_two->[3] eq "4\0ghij";
    print "ok 26\n";
  }
  else {
    print "not ok 22\n";
    print "not ok 23\n";
    print "not ok 24\n";
    print "not ok 25\n";
    print "not ok 26\n";
  }
}

print "ok 27\n";

exit;
