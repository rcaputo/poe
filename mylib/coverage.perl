#!/usr/bin/perl -w
# $Id$

# Runs "make test" with Devel::Cover to check POE's test coverage.
# Generates a quite fine HTML report in the db_cover directory.

use strict;

my $cover = `which cover`; chomp $cover;
my $make  = `which make`;  chomp $make;

system( $make, "distclean" );
system( $^X, "Makefile.PL", "--default" ) and exit($? >> 8);
system( $^X, $cover, "-delete" ) and exit($? >> 8);

{
  local $ENV{PERL5OPT} = "-MDevel::Cover=+ignore,mylib";
  local $ENV{HARNESS_PERL_SWITCHES} = $ENV{PERL5OPT};

  if (@ARGV) {
    foreach my $test (@ARGV) {
      system( $^X, $test ) and exit($? >> 8);
    }
  }
  else {
    system( $make, "test" ) and exit($? >> 8);
  }
}

system( $^X, $cover ) and exit($? >> 8);

exit;
