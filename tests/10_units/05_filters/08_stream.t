#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Stream without the rest of POE.

use strict;
use lib qw(./mylib ../mylib);

use Test::More tests => 8;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok("POE::Filter::Stream") }

my $filter = new POE::Filter::Stream;
my @test_fodder = qw(a bc def ghij klmno);

{ my $received = $filter->get( \@test_fodder );
  ok(
    eq_array($received, [ 'abcdefghijklmno' ]),
    "received combined test items"
  );
}

{ my $sent = $filter->put( \@test_fodder );
  ok(
    eq_array($sent, \@test_fodder),
    "sent each item discretely"
  );
}

{ $filter->get_one_start( \@test_fodder );
  pass("get_one_start didn't die or anything");
}

{ my $pending = $filter->get_pending();
  ok(
    eq_array($pending, [ 'abcdefghijklmno' ]),
    "pending data is correct"
  );
}

{ my $received = $filter->get_one();
  ok(
    eq_array($received, [ 'abcdefghijklmno' ]),
    "get_one() got the right one, baby, uh-huh"
  );
}

{ my $received = $filter->get_one();
  ok(
    eq_array($received, [ ]),
    "get_one() returned an empty array on empty buffer"
  );
}

{ my $pending = $filter->get_pending();
  ok(!defined($pending), "pending data is empty");
}


exit;
