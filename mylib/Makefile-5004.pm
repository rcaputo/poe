#!/usr/bin/perl
# $Id$

use ExtUtils::MakeMaker;

# Add a new target.

sub MY::test {
  package MY;
  "\ntest ::\n\t\$(FULLPERL) ./mylib/deptest.perl\n" . shift->SUPER::test(@_);
}

sub MY::postamble {
    return <<EOF;
reportupload: poe_report.xml
\cIperl mylib/reportupload.pl

uploadreport: poe_report.xml
\cIperl mylib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
\cIperl mylib/testreport.pl

coverage: Makefile
\cIperl mylib/coverage.perl

cover: coverage
EOF
}

# Generate dynamic test files.

system("perl", "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

# Touch generated files so they exist.
open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

rename "t", "tests.tmp" or die "can't rename t -> tests.tmp";

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
    Carp               => 0,
    Exporter           => 0,
    IO                 => 0,
    POSIX              => 0,
    Socket             => 0,
    Filter::Util::Call => 1.04,
    Test::More         => 0,
    File::Spec         => 0,
  },
  PL_FILES    => { },
  clean => {
    FILES => (
      "coverage.report " .
      "poe_report.xml " .
      "run_network_tests " .
      "t/20_resources/10_perl/* " .
      "t/20_resources/20_xs/* " .
      "t/30_loops/10_select/* " .
      "t/30_loops/20_poll/* " .
      "t/30_loops/30_event/* " .
      "t/30_loops/40_gtk/* " .
      "t/30_loops/50_tk/* " .
      "test-output.err "
    ),
  }
);

rename "tests.tmp", "t" or die "can't rename tests.tmp -> t";

1;
