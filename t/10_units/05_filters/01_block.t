#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Exercises Filter::Block without the rest of POE.  Suddenly things
# are looking a lot easier.

use strict;
use lib qw(./mylib ../mylib);
use lib qw(t/10_units/05_filters);

use TestFilter;
use Test::More tests => 20 + $COUNT_FILTER_INTERFACE;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use_ok("POE::Filter::Block");
test_filter_interface("POE::Filter::Block");

# Test block filter in fixed-length mode.
{
  my $filter = new POE::Filter::Block( BlockSize => 4 );
  my $raw    = $filter->put( [ "12345678" ] );

  my $cooked = $filter->get( $raw );
  is_deeply($cooked, [ "1234", "5678" ], "get() parses blocks");

  my $reraw = $filter->put( $cooked );
  is_deeply($reraw, [ "12345678" ], "put() serializes blocks");
}

# Test block filter with get_one() functions.
{
  my $filter = new POE::Filter::Block( BlockSize => 4 );
  my $raw = $filter->put( [ "12345678" ] );

  $filter->get_one_start( $raw );

  my $cooked = $filter->get_one();
  is_deeply($cooked, [ "1234" ], "get_one() parsed one block");

  my $reraw = $filter->put( $cooked );
  is_deeply($reraw, [ "1234" ], "put() serialized one block");
}

# Test block filter in variable-length mode, without a custom codec.
{
  my $filter = new POE::Filter::Block( );
  my $raw = $filter->put([ "a", "bc", "def", "ghij" ]);

  my $cooked = $filter->get( $raw );
  is_deeply(
    $cooked, [ "a", "bc", "def", "ghij" ],
    "get() parsed variable blocks"
  );

  $cooked = $filter->get( [ "1" ] );
  ok(!@$cooked, "get() doesn't return for partial input 1");

  $cooked = $filter->get( [ "0" ] );
  ok(!@$cooked, "get() doesn't return for partial input 0");

  $cooked = $filter->get( [ "\0" ] );
  ok(!@$cooked, "get() doesn't return for partial input end-of-header");

  $cooked = $filter->get( [ "klmno" ] );
  ok(!@$cooked, "get() doesn't return for partial input payload");

  $cooked = $filter->get( [ "pqrst" ] );
  is_deeply($cooked, [ "klmnopqrst" ], "get() returns payload");

  my $raw_two = $filter->put( [ qw(a bc def ghij) ] );
  is_deeply(
    $raw_two, [ "1\0a", "2\0bc", "3\0def", "4\0ghij" ],
    "variable length put() serializes multiple blocks"
  );
}

# Test block filter in variable-length mode, with a custom codec.
{
  sub encoder {
    my $stuff = shift;
    substr($$stuff, 0, 0) = pack("N", length($$stuff));
    undef;
  }

  sub decoder {
    my $stuff = shift;
    return unless length $$stuff >= 4;
    my $packed = substr($$stuff, 0, 4);
    substr($$stuff, 0, 4) = "";
    return unpack("N", $packed);
  }

  my $filter = new POE::Filter::Block(
    LengthCodec => [ \&encoder, \&decoder ],
  );

  my $raw = $filter->put([ "a", "bc", "def", "ghij" ]);

  my $cooked = $filter->get( $raw );
  is_deeply(
    $cooked, [ "a", "bc", "def", "ghij" ],
    "customi serializer parsed its own serialized data"
  );

  $cooked = $filter->get( [ "\x00" ] );
  ok(!@$cooked, "custom serializer did not parse partial header 1/4");

  $cooked = $filter->get( [ "\x00" ] );
  ok(!@$cooked, "custom serializer did not parse partial header 2/4");

  $cooked = $filter->get( [ "\x00" ] );
  ok(!@$cooked, "custom serializer did not parse partial header 3/4");

  $cooked = $filter->get( [ "\x0a" ] );
  ok(!@$cooked, "custom serializer did not parse partial header 4/4");

  $cooked = $filter->get( [ "klmno" ] );
  ok(!@$cooked, "custom serializer did not parse partial payload");

  $cooked = $filter->get( [ "pqrst" ] );
  is_deeply(
    $cooked, [ "klmnopqrst" ],
    "custom serializer parsed full payload"
  );

  my $raw_two = $filter->put( [ qw(a bc def ghij) ] );
  is_deeply(
    $raw_two, [
      "\x00\x00\x00\x01a",
      "\x00\x00\x00\x02bc",
      "\x00\x00\x00\x03def",
      "\x00\x00\x00\x04ghij",
    ],
    "custom serializer serialized multiple payloads"
  );
}

exit;
