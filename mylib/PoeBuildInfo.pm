# vim: ts=2 sw=2 expandtab

# Build information for POE.  Moved into a library so it can be
# required by Makefile.PL and gen-meta.perl.

package PoeBuildInfo;

use strict;

use Exporter;
use vars qw(@ISA @EXPORT_OK);
push @ISA, qw(Exporter);

@EXPORT_OK = qw(
  TEST_FILES
  CLEAN_FILES
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  CONFIG_REQUIREMENTS
  REPOSITORY
  HOMEPAGE
);


sub CONFIG_REQUIREMENTS () {
  (
    "POE::Test::Loops"  => '1.358',
  );
}

sub CORE_REQUIREMENTS () {
  my @core_requirements = (
    "Carp"              => 0,
    "Errno"             => 1.09,
    "Exporter"          => 0,
    "File::Spec"        => 0.87,
    "IO"                => 1.24,  # MSWin32 blocking(0)
    "IO::Handle"        => 1.27,
    "IO::Pipely"        => 0.005,
    "POSIX"             => 1.02,
    "Socket"            => 1.7,
    "Storable"          => 2.16,
    "Test::Harness"     => 2.26,
    "Time::HiRes"       => 1.59,
    CONFIG_REQUIREMENTS,
  );

  if ($^O eq "MSWin32") {
    push @core_requirements, (
      "Win32::Console" => 0.031,
      "Win32API::File" => 0.05,
      "Win32::Job"     => 0.03,
      "Win32::Process" => 0,
      "Win32"          => 0,
    );
  }
  elsif ($^O eq 'cygwin') {
    # Skip IO::Tty.  It has trouble building as of this writing.
  }
  else {
    push @core_requirements, (
      "IO::Tty"        => 1.08, # avoids crashes on fbsd
    );
  }

  return @core_requirements;
}

sub DIST_AUTHOR () {
  ( 'Rocco Caputo <rcaputo@cpan.org>' )
}

sub DIST_ABSTRACT () {
  ( 'Portable, event-loop agnostic eventy networking and multitasking.' )
}

sub CLEAN_FILES () {
  my @clean_files = qw(
    */*/*/*/*~
    */*/*/*~
    */*/*/*~
    */*/*~
    */*~
    *~
    META.yml
    Makefile.old
    bingos-followtail
    coverage.report
    poe_report.xml
    run_network_tests
    t/20_resources/10_perl
    t/20_resources/10_perl/*
    t/20_resources/20_xs
    t/20_resources/20_xs/*
    t/30_loops
    t/30_loops/*
    t/30_loops/*/*
    test-output.err
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
  'https://github.com/rcaputo/poe'
}

sub HOMEPAGE () {
  'http://poe.perl.org/'
}

1;
