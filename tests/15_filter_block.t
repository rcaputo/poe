#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Block without the rest of POE.  Suddenly things
# are looking a lot easier.

use strict;
use lib qw(./lib ../lib);

sub POE::Kernel::TRACE_DEFAULT () { 1 } # not needed though
use POE::Filter::Block;

use TestSetup;
&test_setup(23);

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

# Test block filter in variable-length mode.
{ my $filter = new POE::Filter::Block( );
  my $raw = "1\0a2\0bc3\0def4\0ghij";
  my $cooked = $filter->get( [ $raw ] );
  if (@$cooked == 4) {
    print "ok 7\n";
    print 'not ' unless $cooked->[0] eq 'a';
    print "ok 8\n";
    print 'not ' unless $cooked->[1] eq 'bc';
    print "ok 9\n";
    print 'not ' unless $cooked->[2] eq 'def';
    print "ok 10\n";
    print 'not ' unless $cooked->[3] eq 'ghij';
    print "ok 11\n";

    $cooked = $filter->get( [ "1" ] );
    print 'not ' if @$cooked;
    print "ok 12\n";

    $cooked = $filter->get( [ "0" ] );
    print 'not ' if @$cooked;
    print "ok 13\n";

    $cooked = $filter->get( [ "\0" ] );
    print 'not ' if @$cooked;
    print "ok 14\n";

    $cooked = $filter->get( [ "klmno" ] );
    print 'not ' if @$cooked;
    print "ok 15\n";

    $cooked = $filter->get( [ "pqrst" ] );
    if (@$cooked == 1) {
      print "ok 16\n";
      print 'not ' unless $cooked->[0] eq 'klmnopqrst';
      print "ok 17\n";
    }
    else {
      print "not ok 16\n";
      print "not ok 17\n";
    }
  }
  else {
    print "not ok 7\n";
    print "not ok 8\n";
    print "not ok 9\n";
    print "not ok 10\n";
    print "not ok 11\n";
    print "not ok 12\n";
    print "not ok 13\n";
    print "not ok 14\n";
    print "not ok 15\n";
    print "not ok 16\n";
    print "not ok 17\n";
  }

  my $raw_two = $filter->put( [ qw(a bc def ghij) ] );
  if (@$raw_two == 4) {
    print "ok 18\n";
    print 'not ' unless $raw_two->[0] eq "1\0a";
    print "ok 19\n";
    print 'not ' unless $raw_two->[1] eq "2\0bc";
    print "ok 20\n";
    print 'not ' unless $raw_two->[2] eq "3\0def";
    print "ok 21\n";
    print 'not ' unless $raw_two->[3] eq "4\0ghij";
    print "ok 22\n";
  }
  else {
    print "not ok 18\n";
    print "not ok 19\n";
    print "not ok 20\n";
    print "not ok 21\n";
    print "not ok 22\n";
  }
}

print "ok 23\n";

exit;
