#!/usr/bin/perl -w

# Exercises POE::Filter::RecordBlock without the rest of POE

use strict;
use lib qw(t/10_units/05_filters);

use TestFilter;
use Test::More tests => 21 + $COUNT_FILTER_INTERFACE + $COUNT_FILTER_STANDARD;

use_ok("POE::Filter::RecordBlock");
test_filter_interface("POE::Filter::RecordBlock");

# standard tests and blocksize
{
  my $filter = POE::Filter::RecordBlock->new( BlockSize => 4 );

  test_filter_standard(
    $filter,
    [qw/1 2 3 4 5 6 7 8 9 10/],
    [[qw/1 2 3 4/], [qw/5 6 7 8/]],
    [qw/1 2 3 4 5 6 7 8/],
  );

  is($filter->blocksize(), 4, "blocksize() returns blocksize");
  $filter->blocksize(2);
  is($filter->blocksize(), 2, "blocksize() can be changed");

  eval { $filter->blocksize(undef) };
  eval { local $^W = 0; $filter->blocksize("elephant") };
  eval { $filter->blocksize(-50) };
  eval { $filter->blocksize(0) };
  is($filter->blocksize(), 2, "blocksize() rejects invalid sizes");
}

# new() error checking
{
  eval { POE::Filter::RecordBlock->new( BlockSize => 0 ) };
  ok(!!$@, "BlockSize == 0 fails");
  eval { POE::Filter::RecordBlock->new( ) };
  ok(!!$@, "BlockSize must be given");
  eval { local $^W = 0; POE::Filter::RecordBlock->new( BlockSize => "elephant" ) };
  ok(!!$@, "BlockSize must not be an elephant");
  eval { POE::Filter::RecordBlock->new( "one", "two", "odd number" ) };
  ok(!!$@, "odd number of named parameters is invalid");
}
  
# test checkput
{
  my $filter = POE::Filter::RecordBlock->new( BlockSize => 3, CheckPut => 1 );

  is_deeply(
    $filter->put( [[qw/1 2/], [qw/3 A/]] ),
    [qw/1 2 3/],
    "check put on: short blocks"
  );
  is_deeply(
    $filter->put_pending(),
    [qw/A/],
    "  put_pending"
  );

  is_deeply(
    $filter->put( [[qw/2 3 1 2 3/], [qw/1 2 3 B/]] ),
    [qw/A 2 3 1 2 3 1 2 3/],
    "check put on: long blocks"
  );
  is_deeply(
    $filter->put_pending(),
    [qw/B/],
    "  put_pending"
  );

  is_deeply(
    $filter->put( [[qw/2 3 1 2/], [qw/3 1/], [qw/2 3 1/], [qw/2 3/]] ),
    [qw/B 2 3 1 2 3 1 2 3 1 2 3/],
    "check put on: mixed blocks"
  );
  ok(!defined($filter->put_pending()), "  put_pending");

  ok($filter->checkput(), "checkput() returns CheckPut flag");
  $filter->checkput(0);
  ok(!$filter->checkput(), "checkput() can be changed");
}

# test checkput can be turned off!
{
  my $filter = POE::Filter::RecordBlock->new( BlockSize => 3 );
  ok(!$filter->checkput(), "checkput() returns CheckPut flag");

  is_deeply(
    $filter->put( [[qw/1 2/], [qw/1 2/]] ),
    [qw/1 2 1 2/],
    "check put off: short blocks"
  );

  ok(!defined($filter->put_pending()), "  put_pending is empty");

  is_deeply(
    $filter->put( [[qw/1 2 3 4 5/], [qw/1 2 3 4/]] ),
    [qw/1 2 3 4 5 1 2 3 4/],
    "check put off: long blocks"
  );

  is_deeply(
    $filter->put( [[qw/1 2 3 4/], [qw/1 2/], [qw/1 2 3/], [qw/1 2/]] ),
    [qw/1 2 3 4 1 2 1 2 3 1 2/],
    "check put off: mixed blocks"
  );
}
