#!/usr/bin/perl -w
# $Id$

use strict;

use Test::More tests => 2;

use POE::Preprocessor ( isa => "POE::Macro::UseBytes" );

SKIP: {
  skip("this version of perl is too old for C<use bytes>", 2)
    unless &POE::Macro::UseBytes::HAS_BYTES;

  # Hi, Phi!
  my $test_string = chr(0x618);
  ok(length($test_string) == 1, "Phi is one character");

  {% use_bytes %}
  ok(length($test_string) == 2, "Phi is two bytes");
}

exit 0;
