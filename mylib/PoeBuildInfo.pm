# rocco // vim: ts=2 sw=2 expandtab

# Build information for POE.  Moved into a library so it can be
# required by Makefile.PL and gen-meta.perl.

package PoeBuildInfo;

use strict;

use Exporter;
use base qw(Exporter);
use vars qw(@EXPORT_OK);

@EXPORT_OK = qw(
  TEST_FILES
  CLEAN_FILES
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  RECOMMENDED_TIME_HIRES
  CONFIG_REQUIREMENTS
  REPOSITORY
  HOMEPAGE
);


sub CONFIG_REQUIREMENTS () {
  (
    "POE::Test::Loops"  => '1.035',
  )
}

sub CORE_REQUIREMENTS () {
  (
    "Carp"              => 0,
    "Errno"             => 1.09,
    "Exporter"          => 0,
    "File::Spec"        => 0.87,
    "IO::Handle"        => 1.27,
    "POSIX"             => 1.02,
    "Socket"            => 1.7,
    "Test::Harness"     => 2.26,
    "Storable"          => 2.16,
    (
      ($^O eq "MSWin32")
      ? (
        "Win32::Console" => 0.031,
        "Win32API::File" => 0.05,
        "Win32::Job"     => 0.03,
        "Win32::Process" => 0,
        "Win32"          => 0,
      )
      : (
        "IO::Tty"        => 1.08, # avoids crashes on fbsd
      )
    ),
    CONFIG_REQUIREMENTS,
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
    bingos-followtail
    coverage.report
    poe_report.xml
    run_network_tests
    test-output.err
    t/20_resources/10_perl
    t/20_resources/10_perl/*
    t/20_resources/20_xs
    t/20_resources/20_xs/*
    t/30_loops/*/*
    t/30_loops/*
    t/30_loops
  );
  "@clean_files";
}

sub TEST_FILES () {
  my @test_files = qw(
    t/*.t
    t/*/*.t
    t/*/*/*.t
  );
  "@test_files";
}

sub REPOSITORY () {
  ( 'https://poe.svn.sourceforge.net/svnroot/poe/trunk' )
}

sub HOMEPAGE () {
  ( 'http://poe.perl.org/' )
}

1;
