# $Id$

# Build information for POE.  Moved into a library so it can be
# required by Makefile.PL and gen-meta.perl.

package PoeBuildInfo;

use strict;

use Exporter;
use base qw(Exporter);
use vars qw(@EXPORT_OK);

@EXPORT_OK = qw(
  $clean_files
  $dist_abstract
  $dist_author
  %core_requirements
  %recommended_time_hires
);

my %core_requirements = (
  "Carp"               => 0,
  "Exporter"           => 0,
  "IO"                 => 1.20,
  "POSIX"              => 1.02,
  "Socket"             => 1.7,
  "Filter::Util::Call" => 1.06,
  "Test::More"         => 0.47,
  "File::Spec"         => 0.87,
  "Errno"              => 1.09,
);

my %recommended_time_hires = ( "Time::HiRes" => 1.59 );

my $dist_author   = 'Rocco Caputo <rcaputo@cpan.org>';
my $dist_abstract = 'A portable networking and multitasking framework.';

my @clean_files = qw(
  coverage.report
  poe_report.xml
  run_network_tests
  tests/20_resources/10_perl/*
  tests/20_resources/20_xs/*
  tests/30_loops/10_select/*
  tests/30_loops/20_poll/*
  tests/30_loops/30_event/*
  tests/30_loops/40_gtk/*
  tests/30_loops/50_tk/*
  test-output.err
);
my $clean_files = "@clean_files";

