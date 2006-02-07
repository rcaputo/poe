# $Id$

# Build information for POE.  Moved into a library so it can be
# required by Makefile.PL and gen-meta.perl.

package PoeBuildInfo;

use strict;

use Exporter;
use base qw(Exporter);
use vars qw(@EXPORT_OK);

@EXPORT_OK = qw(
  CLEAN_FILES
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  RECOMMENDED_TIME_HIRES
);

sub CORE_REQUIREMENTS () {
  (
    "Carp"               => 0,
    "Errno"              => 1.09,
    "Exporter"           => 0,
    "File::Spec"         => 0.87,
    "Filter::Util::Call" => 1.06,
    "IO"                 => 1.20,
    "POSIX"              => 1.02,
    "Socket"             => 1.7,
    "Test::Harness"      => 2.26,
  )
}

sub RECOMMENDED_TIME_HIRES () {
  ( "Time::HiRes" => 1.59 )
}

sub DIST_AUTHOR () {
  ( 'Rocco Caputo <rcaputo@cpan.org>' )
}

sub DIST_ABSTRACT () {
  ( 'A portable networking and multitasking framework.' )
}

sub CLEAN_FILES () {
  my @clean_files = qw(
    coverage.report
    poe_report.xml
    run_network_tests
    test-output.err
    tests/20_resources/10_perl
    tests/20_resources/10_perl/*
    tests/20_resources/20_xs
    tests/20_resources/20_xs/*
    tests/30_loops/10_select
    tests/30_loops/10_select/*
    tests/30_loops/20_poll
    tests/30_loops/20_poll/*
    tests/30_loops/30_event
    tests/30_loops/30_event/*
    tests/30_loops/40_gtk
    tests/30_loops/40_gtk/*
    tests/30_loops/50_tk
    tests/30_loops/50_tk/*
  );
  "@clean_files";
}

1;
