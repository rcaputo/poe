#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Stack (and friends) without the rest of POE.

use strict;
use lib qw(./lib ../lib);

use POE::Filter::Stackable;
use POE::Filter::Grep;
use POE::Filter::Map;
use POE::Filter::RecordBlock;
use POE::Filter::Line;

use TestSetup;
&test_setup(8);

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

&results;

exit 0;
