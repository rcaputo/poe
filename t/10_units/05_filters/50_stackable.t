#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Exercises Filter::Stack (and friends) without the rest of POE.

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use Test::More tests => 29;

use_ok('POE::Filter::Stackable');
use_ok('POE::Filter::Grep');
use_ok('POE::Filter::Map');
use_ok('POE::Filter::RecordBlock');
use_ok('POE::Filter::Line');

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

my $pending = $filter_stack->get_pending();
is_deeply(
  $pending, [ "(((test one (1))))" ],
  "filter stack has correct get_pending"
);

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

### Go back and test more of Stackable.

{
  my @filters_should_be = qw(
		POE::Filter::Line POE::Filter::Map POE::Filter::Grep
		POE::Filter::RecordBlock
	);
  my @filters_are  = $filter_stack->filter_types();
  is_deeply(\@filters_are, \@filters_should_be,
    "filter types stacked correctly");
}

# test pushing and popping
{
  my @filters_strlist = map { "$_" } $filter_stack->filters();

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

  my @filters_strlist_end = map { "$_" } $filter_stack->filters();
  is_deeply(\@filters_strlist_end, \@filters_strlist,
    "repushed, reshifted filters are in original order");
}

# push error checking
{
  my @filters_strlist = map { "$_" } $filter_stack->filters();

  eval { $filter_stack->push(undef) };
  ok(!!$@, "undef is not a filter");

  eval { $filter_stack->push(['i am not a filter']) };
  ok(!!$@, "bare references are not filters");

  eval { $filter_stack->push(bless(['i am not a filter'], "foo$$")) };
  ok(!!$@, "random blessed references are not filters");
  # not blessed into a package that ISA POE::Filter

  eval { $filter_stack->push(123, "two not-filter things") };
  ok(!!$@, "multiple non-filters are not filters");

  my @filters_strlist_end = map { "$_" } $filter_stack->filters();
  is_deeply(\@filters_strlist_end, \@filters_strlist,
    "filters unchanged despite errors");
}

# test cloning
{
  my @filters_strlist = map { "$_" } $filter_stack->filters();
  my @filter_types = $filter_stack->filter_types();

  my $new_stack = $filter_stack->clone();

  isnt("$new_stack", "$filter_stack", "cloned stack is different");
  isnt(join('---', @filters_strlist),
    join('---', $new_stack->filters()),
    "filters are different");
  is_deeply(\@filter_types, [$new_stack->filter_types()],
    "but types are the same");
}

exit 0;
