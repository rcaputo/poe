#!/usr/bin/perl -w
# $Id$

# Tests basic macro features.

use strict;

use lib qw(./mylib);
use Test::More tests => 18;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok("POE::Preprocessor") };

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

ok(NUM_ZERO   == 0,  "NUM\_ZERO == 0");
ok(NUM_ONE    == 1,  "NUM\_ONE == 1");
ok(NUM_TWO    == 2,  "NUM\_TWO == 2");
ok(NUM_TEN    == 10, "NUM\_TEN == 10");
ok(NUM_ELEVEN == 11, "NUM\_ELEVEN == 11");

ok(LEX_ONE eq 'one', "LEX\_ONE eq one");
ok(LEX_TWO eq 'two', "LEX\_TWO eq two");

# Test the macros.

ok( {% numeric_max NUM_ONE, NUM_TWO %}    == 2,  "numeric_max" );
ok( {% numeric_min NUM_TEN, NUM_ELEVEN %} == 10, "numeric_min" );
ok( {% lexical_max LEX_ONE, LEX_TWO %} eq 'two', "lexical_max" );
ok( {% lexical_min LEX_ONE, LEX_TWO %} eq 'one', "lexical_min" );

# Test conditional code.

my $test = "conditional unless";
unless (1) {                            # include
  fail($test);
} else {                                # include
  pass($test);
}                                       # include

$test = "conditional if/elsif";
if (0) {                                # include
  fail($test);
} elsif (1) {                           # include
  pass($test);
} else {                                # include
  fail($test);
}                                       # include

if (0) {                                # include
  fail("outer if, before unless");
  unless (1) {                          # include
    fail("inner unless");
  } else {                              # include
    fail("inner unless");
  }                                     # include
  fail("outer if, after unless");
} else {                                # include
  pass("outer if, before unless");
  unless (1) {                          # include
    fail("inner unless");
  } else {                              # include
    pass("inner unless");
  }                                     # include
  pass("outer if, after unless");
}                                       # include

pass("end of tests");

exit;
