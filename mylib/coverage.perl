#!/usr/bin/perl -w
# $Id$

# Runs "make test" with Devel::Cover to check POE's test coverage.
# Generates a quite fine HTML report in the db_cover directory.

use strict;
use Cwd;

my $cover = `which cover`; chomp $cover;
my $make  = `which make`;  chomp $make;

my $output_dir = cwd() . "/cover_db";

system( $make, "distclean" );
system( $^X, "Makefile.PL", "--default" )     and exit($? >> 8);
system( $make )                               and exit($? >> 8);
if (-e $output_dir) {
  system( $^X, $cover, "-delete", $output_dir ) and exit($? >> 8);
}

my $hps = $ENV{HARNESS_PERL_SWITCHES} || "";
$hps =~ s/~/$ENV{HOME}/g;

my @includes = ("mylib", $hps =~ /-I\s*(\S+)/g);
$hps =~ s/(?<=-I)\s+//g;

my $ignores = join(",", map("+ignore,$_", @includes));

warn "*** Ignores: $ignores";

{
  my $perl5_options = "-MDevel::Cover";
  $perl5_options .= "=$ignores" if $ignores;

  warn "*** PERL5OPT = $perl5_options";
  local $ENV{PERL5OPT} = $perl5_options;

  my $harness_switches = "$hps $perl5_options";
  $harness_switches =~ s/^\s+//;
  $harness_switches =~ s/\s+$//;
  warn "*** HARNESS_PERL_SWITCHES = $harness_switches";


  #local $ENV{HARNESS_PERL_SWITCHES} = $harness_switches;

  if (@ARGV) {
    foreach my $test (@ARGV) {
      system( $^X, $hps, $test ) and exit($? >> 8);
    }
  }
  else {
    system( $make, "test" ) and exit($? >> 8);
  }
}

system( $^X, $cover, $output_dir ) and exit($? >> 8);

exit;
