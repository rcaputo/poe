#!/usr/bin/perl
# $Id$

use ExtUtils::MakeMaker;
use File::Find;
use File::Spec;

# Add a new target.

sub MY::test {
  package MY;
  "\ntest ::\n\t\$(FULLPERL) ./mylib/deptest.perl\n" . shift->SUPER::test(@_);
}

sub MY::postamble {
    return <<EOF;
reportupload: poe_report.xml
	perl mylib/reportupload.pl

uploadreport: poe_report.xml
	perl mylib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
	perl mylib/testreport.pl
EOF
}

my @tests;

find(
  sub {
    /\.t$/ &&
    push @tests, File::Spec->catfile($File::Find::dir,$_)
  },
  't/',
);

my $test_str = join " ", sort @tests;

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
  test           => { TESTS => $test_str },
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
    FILES => 'poe_report.xml test-output.err coverage.report run_network_tests',
  }
);

1;
