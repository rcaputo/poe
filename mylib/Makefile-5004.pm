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
	perl mylib/reportupload.pl

uploadreport: poe_report.xml
	perl mylib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
	perl mylib/testreport.pl
EOF

}

# Touch CHANGES so it exists.
open(CHANGES, ">>CHANGES") and close CHANGES;

WriteMakefile
  ( NAME           => 'POE',
    VERSION_FROM   => 'POE.pm',

    dist           =>
    { COMPRESS => 'gzip -9f',
      SUFFIX   => 'gz',
      PREOP    => ( './mylib/cvs-log.perl | ' .
                    'tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES'
                  ),
    },
    test           => { TESTS => 't/*/*.t t/*.t' },
    PREREQ_PM      => { Carp               => 0,
                        Exporter           => 0,
                        IO                 => 0,
                        POSIX              => 0,
                        Socket             => 0,
                        Filter::Util::Call => 1.04,
                        Test::More         => 0,
                      },
    PMLIBDIRS      => [ 'POE' ],
    clean => {
        FILES => 'poe_report.xml test-output.err coverage.report',
    }
  );

1;
