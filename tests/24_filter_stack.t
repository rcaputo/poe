#!/usr/bin/perl -w
# $Id$

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

use TestSetup;
&test_setup(26);

# Create a filter stack to test.

my $filter_stack = POE::Filter::Stackable->new
  ( Filters =>
    [ POE::Filter::Line->new( Literal => "!" ),

      # The next Map filter translates Put data from RecordBlock
      # (arrayrefs) into scalars for Line.  On the Get side, it just
      # wraps parens around whatever Line returns.

      POE::Filter::Map->new ( Put => sub { @$_        }, # scalarify puts
                              Get => sub { "((($_)))" }, # transform gets
                            ),
      POE::Filter::Grep->new( Put => sub { 1          }, # always put
                              Get => sub { /1/        }, # only get /1/
                            ),

      # RecordBlock puts arrayrefs.  They pass through Grep->Put
      # without change.  RecordBlock receives whatever-- lines in this
      # case, but only ones that match /1/ from Grep->Get.

      POE::Filter::RecordBlock->new( BlockSize => 2 ),
    ]
  );

&ok_if( 1, defined $filter_stack );

my $block = $filter_stack->get( [ "test one (1)!test two (2)!" ] );
&ok_unless( 2, @$block );

$block = $filter_stack->get( [ "test three (3)!test four (100)!" ] );
&ok_if( 3, @$block == 1 );
&ok_if( 4, $block->[0]->[0] eq '(((test one (1))))' );
&ok_if( 5, $block->[0]->[1] eq '(((test four (100))))' );

# Make a copy of the block.  Bad things happen when both blocks have
# the same reference because we're passing by reference a lot.

my $stream = $filter_stack->put( [ $block, $block ] );
&ok_if( 6, @$stream == 4 );

&ok_if( 7, $stream->[0] eq $stream->[2] );
&ok_if( 8, $stream->[1] eq $stream->[3] );

# Test some of the discrete stackable filters by themselves.

my @test_list = (1, 1, 2, 3, 5);

# Map

my $map = POE::Filter::Map->new( Code => sub { "((($_)))" } );
$map->get_one_start( [ @test_list ] );

my $map_pending = join '', @{$map->get_pending()};
&ok_if( 9, $map_pending eq '11235' );

my $map_test_number = 10;
foreach my $compare (@test_list) {
  my $next = $map->get_one();

  &ok_if( $map_test_number++,
          ( defined($next) and
            (@$next == 1)  and
            ("((($compare)))" eq $next->[0])
          )
        );
}

my $map_next = $map->get_one();
&ok_unless( $map_test_number, @$map_next );

# Grep

my $grep = POE::Filter::Grep->new( Code => sub { $_ & 1 } );
$grep->get_one_start( [ @test_list ] );

my $grep_pending = join '', @{$grep->get_pending()};
&ok_if( 16, $grep_pending eq '11235' );

my $grep_test_number = 17;
foreach my $compare (@test_list) {
  next unless $compare & 1;

  my $next = $grep->get_one();

  &ok_if( $grep_test_number++,
          ( defined($next) and
            (@$next == 1)  and
            ($compare == $next->[0])
          )
        );
}

my $grep_next = $grep->get_one();
&ok_unless( $grep_test_number, @$grep_next );

### Go back and test more of Stackable.

my @filters_should_be = qw( Line Map Grep RecordBlock );

my $filters_are  = join ' --- ', $filter_stack->filter_types();
my $filters_test = join ' --- ', @filters_should_be;

&ok_if( 22, $filters_test eq $filters_are );

my $filters_also_are  =
  join ' --- ', map { ref($_) } $filter_stack->filters();
my $filters_also_test =
  join ' --- ', map { 'POE::Filter::' . $_ } @filters_should_be;

&ok_if( 23, $filters_also_test eq $filters_also_are );

my $filter_pop = $filter_stack->pop();
&ok_if( 24, ref($filter_pop) eq 'POE::Filter::RecordBlock' );

my $filter_shift = $filter_stack->shift();
&ok_if( 25, ref($filter_shift) eq 'POE::Filter::Line' );

$filter_stack->push( $filter_pop );
$filter_stack->unshift( $filter_shift );

my $filters_are_again = join ' --- ', $filter_stack->filter_types();

&ok_if( 26, $filters_test eq $filters_are_again );

&results;

exit 0;
