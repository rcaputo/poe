#!/usr/bin/perl -w
# $Id$

# Tests basic macro features.

use strict;
use lib qw(./mylib ../mylib .. .);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

test_setup(20);

use POE::Preprocessor;

# Did we get this far?

print "ok 1\n";

# Define some macros.

macro numeric_max (<one>, <two>) {
  (((<one>) > (<two>)) ? (<one>) : (<two>))
}

macro numeric_min (<one>, <two>) {
  (((<one>) < (<two>)) ? (<one>) : (<two>))
}

macro lexical_max (<one>, <two>) {
  (((<one>) gt (<two>)) ? (<one>) : (<two>))
}

macro lexical_min (<one>, <two>) {
  (((<one>) lt (<two>)) ? (<one>) : (<two>))
}

# Define some constants.

const LEX_ONE 'one'
const LEX_TWO 'two'

enum NUM_ZERO NUM_ONE NUM_TWO
enum 10 NUM_TEN
enum + NUM_ELEVEN

# Test the enumerations and constants first.

sub test_number {
  my ($test, $one, $two) = @_;
  print "not " unless $one == $two;
  print "ok $test\n";
}

&test_number(2, NUM_ZERO,    0);
&test_number(3, NUM_ONE,     1);
&test_number(4, NUM_TWO,     2);
&test_number(5, NUM_TEN,    10);
&test_number(6, NUM_ELEVEN, 11);

sub test_string {
  my ($test, $one, $two) = @_;
  print "not " unless $one eq $two;
  print "ok $test\n";
}

&test_string(7, LEX_ONE, 'one');
&test_string(8, LEX_TWO, 'two');

# Test the macros.

print "not " unless {% numeric_max NUM_ONE, NUM_TWO %} == 2;
print "ok 9\n";

print "not " unless {% numeric_min NUM_TEN, NUM_ELEVEN %} == 10;
print "ok 10\n";

print "not " unless {% lexical_max LEX_ONE, LEX_TWO %} eq 'two';
print "ok 11\n";

print "not " unless {% lexical_min LEX_ONE, LEX_TWO %} eq 'one';
print "ok 12\n";

# Test conditional code.

unless (1) {                            # include
  print 'not ';
} else {                                # include
  print "ok 13\n";
}                                       # include

if (0) {                                # include
  print "not ok 14\n";
} elsif (1) {                           # include
  print "ok 14\n";
} else {                                # include
  print "not ok 15\n";
}                                       # include

print "ok 15\n";

if (0) {                                # include
  print "not ok 16\n";
  unless (1) {                          # include
    print "not ok 17\n";
  } else {                              # include
    print "not ok 18\n";
  }                                     # include
  print "not ok 19\n";
} else {                                # include
  print "ok 16\n";
  unless (1) {                          # include
    print "not ok 17\n";
  } else {                              # include
    print "ok 17\n";
    print "ok 18\n";
  }                                     # include
  print "ok 19\n";
}                                       # include

print "ok 20\n";

exit;
