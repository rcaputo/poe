#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Line without the rest of POE.

use strict;
use lib qw(./lib ../lib);

sub POE::Kernel::TRACE_DEFAULT () { 1 } # not needed though
use POE::Filter::Line;

my ($filter, $received, $sent, $base);

use TestSetup;
&test_setup(47);

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
my $compiled_regexp = eval "qr/[xy]/" if $] >= 5.005;

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
    print "ok ", $base+$_, " # skipped: compiled regexps not supported\n";
  }
}

# Test newline autodetection.  \x0D\x0A split between lines.
$base   = 32;
$filter = POE::Filter::Line->new( InputLiteral  => undef,
                                  OutputLiteral => '!',
                                ); # autodetect

my @received;
foreach ("a\x0d", "\x0Ab\x0D\x0A", "c\x0A\x0D", "\x0A") {
  my $local_received = $filter->get( [ $_ ] );
  if (defined $local_received and @$local_received) {
    push @received, @$local_received;
  }
}

if (@received == 3) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( \@received );

  if (@$sent == 3) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "a!";     print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "b!";     print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "c\x0A!"; print "ok ", $base+4, "\n";
  }
  else {
    for (1..4) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..4) { print "not ok ", $base+$_, "\n"; }
}

# Test newline autodetection.  \x0A\x0D on first line.
$base   = 37;
$filter = POE::Filter::Line->new( InputLiteral  => undef,
                                  OutputLiteral => '!',
                                ); # autodetect

undef @received;
foreach ("a\x0A\x0D", "\x0Db\x0A\x0D", "c\x0D", "\x0A\x0D") {
  my $local_received = $filter->get( [ $_ ] );
  if (defined $local_received and @$local_received) {
    push @received, @$local_received;
  }
}

if (@received == 3) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( \@received );

  if (@$sent == 3) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "a!";     print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "\x0Db!"; print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "c\x0D!"; print "ok ", $base+4, "\n";
  }
  else {
    for (1..4) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..4) { print "not ok ", $base+$_, "\n"; }
}

# Test newline autodetection.  \x0A by itself, with suspicion.
$base   = 42;
$filter = POE::Filter::Line->new( InputLiteral  => undef,
                                  OutputLiteral => '!',
                                ); # autodetect

undef @received;
foreach ("a\x0A", "b\x0D\x0A", "c\x0D", "\x0A") {
  my $local_received = $filter->get( [ $_ ] );
  if (defined $local_received and @$local_received) {
    push @received, @$local_received;
  }
}

if (@received == 3) {
  print "ok ", $base+0, "\n";
  $sent = $filter->put( \@received );

  if (@$sent == 3) {
    print "ok ", $base+1, "\n";
    print 'not ' unless $sent->[0] eq "a!";     print "ok ", $base+2, "\n";
    print 'not ' unless $sent->[1] eq "b\x0D!"; print "ok ", $base+3, "\n";
    print 'not ' unless $sent->[2] eq "c\x0D!"; print "ok ", $base+4, "\n";
  }
  else {
    for (1..4) { print "not ok ", $base+$_, "\n"; }
  }
}
else {
  for (0..4) { print "not ok ", $base+$_, "\n"; }
}


# And one to grow on!
print "ok 47\n";
