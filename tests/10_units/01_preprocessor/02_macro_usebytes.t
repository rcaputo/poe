#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

use POE::Preprocessor ( isa => "POE::Macro::UseBytes" );

SKIP: {
  # Hi, Phi!
  my $test_string = chr(0x618);
  ok(length($test_string) == 1, "Phi is one character");

  {% use_bytes %}
  ok(length($test_string) == 2, "Phi is two bytes");
}

exit 0;
