#!/usr/bin/perl
# $Id$

use ExtUtils::MakeMaker;

# Add a new target.

sub MY::postamble {
    return <<EOF;
reportupload: poe_report.xml
\cI$^X mylib/reportupload.pl

uploadreport: poe_report.xml
\cI$^X mylib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
\cI$^X mylib/testreport.pl

coverage: Makefile
\cI$^X mylib/coverage.perl

cover: coverage
EOF
}

# Generate dynamic test files.

system($^X, "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

# Touch generated files so they exist.
open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

WriteMakefile(
  NAME           => 'POE',
  VERSION_FROM   => 'lib/POE.pm',

  dist           => {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
    PREOP    => (
      './mylib/cvs-log.perl | ' .
      'tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES'
    ),
  },
  PREREQ_PM      => {
    "Carp"               => 0,
    "Exporter"           => 0,
    "IO"                 => 1.20,
    "POSIX"              => 1.02,
    "Socket"             => 1.7,
    "Filter::Util::Call" => 1.06,
    "Test::More"         => 0.50,
    "File::Spec"         => 3.01,
    "Errno"              => 1.09,
  },
  PL_FILES    => { },
  clean => {
    FILES => (
      "coverage.report " .
      "poe_report.xml " .
      "run_network_tests " .
      "tests/20_resources/10_perl/* " .
      "tests/20_resources/20_xs/* " .
      "tests/30_loops/10_select/* " .
      "tests/30_loops/20_poll/* " .
      "tests/30_loops/30_event/* " .
      "tests/30_loops/40_gtk/* " .
      "tests/30_loops/50_tk/* " .
      "test-output.err "
    ),
  }
);

1;
