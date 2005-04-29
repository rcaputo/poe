#!/usr/bin/perl
# $Id$

use strict;

use ExtUtils::MakeMaker;

use lib qw(./mylib);
use PoeBuildInfo qw(
  CLEAN_FILES
  CORE_REQUIREMENTS
);

### Touch files that will be generated at "make dist" time.
### ExtUtils::MakeMaker and Module::Build will complain about them if
### they aren't present now.

open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

### Generate dynamic test files.

system($^X, "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

### Generate Makefile.PL.

#sub MY::postamble {
#    return <<EOF;
#reportupload: poe_report.xml
#\cI$^X mylib/reportupload.pl
#
#uploadreport: poe_report.xml
#\cI$^X mylib/reportupload.pl
#
#testreport: poe_report.xml
#
#poe_report.xml: Makefile
#\cI$^X mylib/testreport.pl
sub MY::postamble {
    return <<EOF;
coverage: Makefile
\cI$^X mylib/coverage.perl

cover: coverage

ppmdist:
\cIecho Use a modern version of Perl to build the PPM distribution.
\cIfalse
EOF
}

WriteMakefile(
  NAME           => 'POE',
  VERSION_FROM   => 'lib/POE.pm',

  dist           => {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
    PREOP    => (
      'echo Use a modern version of Perl to build distributions.; ' .
      'false'
    ),
  },

  clean => {
    FILES => CLEAN_FILES,
  },

  PL_FILES    => { },
  PREREQ_PM => { CORE_REQUIREMENTS },
);

1;
