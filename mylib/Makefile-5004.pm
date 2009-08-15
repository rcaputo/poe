#!/usr/bin/perl
# rocco // vim: ts=2 sw=2 expandtab

use strict;

use ExtUtils::MakeMaker;

use lib qw(./mylib);
use PoeBuildInfo qw(
  TEST_FILES
  CLEAN_FILES
  CORE_REQUIREMENTS
);

### Touch files that will be generated at "make dist" time.
### ExtUtils::MakeMaker and Module::Build will complain about them if
### they aren't present now.

open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

### Touch gen-tests.perl so it always triggers.

utime(time(), time(), "mylib/gen-tests.perl");

### Generate Makefile.PL.

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

  test => {
    TESTS => TEST_FILES,
  },

  # Not executed on "make test".
  PL_FILES  => {
    'mylib/gen-tests.perl' => [ 'lib/POE.pm' ],
  },

  PREREQ_PM => { CORE_REQUIREMENTS },
);

1;
