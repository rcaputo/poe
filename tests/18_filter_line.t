#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Line without the rest of POE.

use strict;
use lib qw(./lib ../lib);
use POE::Filter::Line;

my ($filter, $received, $sent, $base);

use TestSetup;
&test_setup(32);

# Self-congratulatory backpatting.
print "ok 1\n";

# Test the line filter in default mode.
$base   = 2;
$filter = POE::Filter::Line->new();

$received = $filter->get( [ "a\x0D", "b\x0A", "c\x0D\x0A", "d\x0A\x0D" ] );
if (@$received == 4) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( $received );
  if (@$sent == 4) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "a\x0D\x0A"; print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "b\x0D\x0A"; print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "c\x0D\x0A"; print "ok ", $base+4, "\n";
    print 'not ' unless $sent->[3] eq "d\x0D\x0A"; print "ok ", $base+5, "\n";
  }
  else {
    for (1..5) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..5) { print "not ok ", $base+$_, "\n"; }
}

# Test the line filter in literal mode.
$base   = 8;
$filter = POE::Filter::Line->new( Literal => 'x' );

$received = $filter->get( [ "axa", "bxb", "cxc", "dxd" ] );
if (@$received == 4) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( $received );
  if (@$sent == 4) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "ax";  print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "abx"; print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "bcx"; print "ok ", $base+4, "\n";
    print 'not ' unless $sent->[3] eq "cdx"; print "ok ", $base+5, "\n";
  }
  else {
    for (1..5) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..5) { print "not ok ", $base+$_, "\n"; }
}

# Test the line filter with different input and output literals.
$base   = 14;
$filter = POE::Filter::Line->new( InputLiteral  => 'x',
                                  OutputLiteral => 'y',
                                );

$received = $filter->get( [ "axa", "bxb", "cxc", "dxd" ] );
if (@$received == 4) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( $received );
  if (@$sent == 4) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "ay";  print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "aby"; print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "bcy"; print "ok ", $base+4, "\n";
    print 'not ' unless $sent->[3] eq "cdy"; print "ok ", $base+5, "\n";
  }
  else {
    for (1..5) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..5) { print "not ok ", $base+$_, "\n"; }
}

# Test the line filter with an input string regexp and an output
# literal.
$base   = 20;
$filter = POE::Filter::Line->new( InputRegexp   => '[xy]',
                                  OutputLiteral => '!',
                                );

$received = $filter->get( [ "axa", "byb", "cxc", "dyd" ] );
if (@$received == 4) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( $received );
  if (@$sent == 4) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "a!";  print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "ab!"; print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "bc!"; print "ok ", $base+4, "\n";
    print 'not ' unless $sent->[3] eq "cd!"; print "ok ", $base+5, "\n";
  }
  else {
    for (1..5) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..5) { print "not ok ", $base+$_, "\n"; }
}

# Test the line filter with an input compiled regexp and an output
# literal.

$base = 26;
my $compiled_regexp;
BEGIN { eval { $compiled_regexp = qr/[xy]/; }; };

if (defined $compiled_regexp) {
  $filter = POE::Filter::Line->new( InputRegexp   => $compiled_regexp,
                                    OutputLiteral => '!',
                                  );

  $received = $filter->get( [ "axa", "byb", "cxc", "dyd" ] );
  if (@$received == 4) {
    print "ok ", $base+0, "\n";
    $sent = $filter->put( $received );
    if (@$sent == 4) {
      print "ok ", $base+1, "\n";
      print 'not ' unless $sent->[0] eq "a!";  print "ok ", $base+2, "\n";
      print 'not ' unless $sent->[1] eq "ab!"; print "ok ", $base+3, "\n";
      print 'not ' unless $sent->[2] eq "bc!"; print "ok ", $base+4, "\n";
      print 'not ' unless $sent->[3] eq "cd!"; print "ok ", $base+5, "\n";
    }
    else {
      for (1..5) { print "not ok ", $base+$_, "\n"; }
    }
  }
  else {
    for (0..5) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..5) {
    print "skip ", $base+$_, " # compiled regexps not supported\n";
  }
}

# And one to grow on!
print "ok 32\n";
