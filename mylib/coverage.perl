#!/usr/bin/perl -w
# $Id$

# Runs "make test" with Devel::Cover to check POE's test coverage.
# Generates a quite fine HTML report in the db_cover directory.

use strict;
use Cwd;
use Getopt::Long;

#   HARNESS_PERL_SWITCHES=$(perl mylib/coverage.perl --coverflags) prove -br tests/10_units/

my ($opt_coverflags, $opt_prove, $opt_noclean);
GetOptions(
  'coverflags' => \$opt_coverflags,
  'prove' => sub { $opt_prove = 1; die "!FINISH" },
  'noclean' => \$opt_noclean,
) or die "$0: usage\n";

my $cover = `which cover`; chomp $cover;
my $prove = `which prove`; chomp $prove;
my $make  = `which make`;  chomp $make;

my $output_dir = cwd() . "/cover_db";

my $hps = $ENV{HARNESS_PERL_SWITCHES} || "";
$hps =~ s/~/$ENV{HOME}/g;

my @includes = ("mylib", $hps =~ /-I\s*(\S+)/g);
$hps =~ s/(?<=-I)\s+//g;

my $ignores = join(",", map("+inc,$_", @includes), "+ignore,^tests/");
warn "*** Ignores: $ignores";

my $cover_options = "-MDevel::Cover";
$cover_options .= "=$ignores" if $ignores;

if ($opt_coverflags) {
  print $cover_options, "\n";
  exit 0;
}

# preparation/cleaning steps
unless ($opt_noclean) {
  system( $make, "distclean" );
  system( $^X, "Makefile.PL", "--default" )     and exit($? >> 8);
  system( $make )                               and exit($? >> 8);
  if (-e $output_dir) {
    system( $^X, $cover, "-delete", $output_dir ) and exit($? >> 8);
  }
}

# run the test suite in the coverage environment
{
  my $harness_switches = "$hps $cover_options";
  $harness_switches =~ s/^\s+//;
  $harness_switches =~ s/\s+$//;
  warn "*** HARNESS_PERL_SWITCHES = $harness_switches";

  local $ENV{HARNESS_PERL_SWITCHES} = $harness_switches;

  if ($opt_prove) {
    warn "*** proving: $^X $prove @ARGV";
    system( $^X, $prove, @ARGV ) and exit($? >> 8);
  }
  elsif (@ARGV) {
    # it might be more useful to punt to prove(1), but prove isn't always
    # available,  maybe a --prove flag
    foreach my $test (@ARGV) {
      warn "*** running: $^X $harness_switches $test";
      system( $^X, $harness_switches, $test ) and exit($? >> 8);
    }
  }
  else {
    system( $make, "test" ) and exit($? >> 8);
  }
}

# coverage report
system( $^X, $cover, $output_dir ) and exit($? >> 8);

warn "*** used ".((times)[2] + (times)[3])." seconds of CPU";

exit;

__END__

=head1 NAME

coverage.perl -- A command-line tool for producing coverage reports of POE

=head1 SYNOPSIS

coverage.perl [options] [tests]

Options:

    --coverflags       Print out the -MDevel::Cover option that would have
                       been used, then exit.
    --noclean          Do not clean and rebuild source tree or cover_db
    --prove            Run the prove utility with the rest of the command line
