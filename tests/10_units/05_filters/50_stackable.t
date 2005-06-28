#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl

# Exercises Filter::Stack (and friends) without the rest of POE.

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE::Filter::Stackable;
use POE::Filter::Grep;
use POE::Filter::Map;
use POE::Filter::RecordBlock;
use POE::Filter::Line;

use Test::More tests => 22;

# Create a filter stack to test.

my $filter_stack = POE::Filter::Stackable->new(
  Filters => [
    POE::Filter::Line->new( Literal => "!" ),

    # The next Map filter translates Put data from RecordBlock
    # (arrayrefs) into scalars for Line.  On the Get side, it just
    # wraps parens around whatever Line returns.

    POE::Filter::Map->new(
      Put => sub { @$_        }, # scalarify puts
      Get => sub { "((($_)))" }, # transform gets
    ),
    POE::Filter::Grep->new(
      Put => sub { 1          }, # always put
      Get => sub { /1/        }, # only get /1/
    ),

    # RecordBlock puts arrayrefs.  They pass through Grep->Put
    # without change.  RecordBlock receives whatever-- lines in this
    # case, but only ones that match /1/ from Grep->Get.

    POE::Filter::RecordBlock->new( BlockSize => 2 ),
  ]
);

ok(defined($filter_stack), "filter stack created");

my $block = $filter_stack->get( [ "test one (1)!test two (2)!" ] );
ok(!@$block, "partial get returned nothing");

$block = $filter_stack->get( [ "test three (3)!test four (100)!" ] );
is_deeply(
  $block, [ [ "(((test one (1))))", "(((test four (100))))" ] ],
  "filter stack returned correct data"
);

# Make a copy of the block.  Bad things happen when both blocks have
# the same reference because we're passing by reference a lot.

my $stream = $filter_stack->put( [ $block, $block ] );

is_deeply(
  $stream,
  [
    "(((test one (1))))!", "(((test four (100))))!",
    "(((test one (1))))!", "(((test four (100))))!",
  ],
  "filter stack serialized correct data"
);

# Test some of the discrete stackable filters by themselves.

my @test_list = (1, 1, 2, 3, 5);

# Map

my $map = POE::Filter::Map->new( Code => sub { "((($_)))" } );
$map->get_one_start( [ @test_list ] );

my $map_pending = join '', @{$map->get_pending()};
ok($map_pending eq "11235", "map filter's parser buffer verifies");

foreach my $compare (@test_list) {
  my $next = $map->get_one();
  is_deeply(
    $next, [ "((($compare)))" ],
    "map filter get_one() returns ((($compare)))"
  );
}

my $map_next = $map->get_one();
ok(!@$map_next, "nothing left to get from map filter");

# Grep

my $grep = POE::Filter::Grep->new( Code => sub { $_ & 1 } );
$grep->get_one_start( [ @test_list ] );

my $grep_pending = join '', @{$grep->get_pending()};
ok($grep_pending eq '11235', "grep filter's parser buffer verifies");

foreach my $compare (@test_list) {
  next unless $compare & 1;
  my $next = $grep->get_one();
  is_deeply($next, [ $compare ], "grep filter get_one() returns [$compare]");
}

my $grep_next = $grep->get_one();
ok(!@$grep_next, "nothing left to get from grep filter");

### Go back and test more of Stackable.

my @filters_should_be = qw( Line Map Grep RecordBlock );

my $filters_are  = join ' --- ', $filter_stack->filter_types();
my $filters_test = join ' --- ', @filters_should_be;

ok($filters_test eq $filters_are, "filter types stacked correctly");

my $filters_also_are  = (
  join ' --- ', map { ref($_) } $filter_stack->filters()
);
my $filters_also_test = (
  join ' --- ', map { 'POE::Filter::' . $_ } @filters_should_be
);

ok(
  $filters_also_test eq $filters_also_are,
  "filters stacked correctly"
);

my $filter_pop = $filter_stack->pop();
ok(
  ref($filter_pop) eq "POE::Filter::RecordBlock",
  "popped the correct filter"
);

my $filter_shift = $filter_stack->shift();
ok(
  ref($filter_shift) eq 'POE::Filter::Line',
  "shifted the correct filter"
);

$filter_stack->push( $filter_pop );
$filter_stack->unshift( $filter_shift );

my $filters_are_again = join ' --- ', $filter_stack->filter_types();

ok(
  $filters_test eq $filters_are_again,
  "repushed, reshifted filters are in order"
);

exit 0;
