#!/usr/bin/perl
# $Id$

use ExtUtils::MakeMaker;

# Add a new target.

sub MY::test {
  package MY;
  "\ntest ::\n\t\$(FULLPERL) ./lib/deptest.perl\n" . shift->SUPER::test(@_);
}

sub MY::postamble {
    return <<EOF;
reportupload: poe_report.xml
	perl lib/reportupload.pl

uploadreport: poe_report.xml
	perl lib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
	perl lib/testreport.pl
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
      PREOP    => ( './lib/cvs-log.perl | ' .
                    'tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES'
                  ),
    },
    PREREQ_PM      => { Carp               => 0,
                        Exporter           => 0,
                        IO                 => 0,
                        POSIX              => 0,
                        Socket             => 0,
                        Filter::Util::Call => 1.04,
                      },

    # Remove 'lib', which should have been named 'privlib'.  The 'lib'
    # directory in this distribution is for private stuff needed to
    # build and test POE.  Those things should not be installed!  At
    # some point SourceForge will open up shell access to my CVS tree
    # there, and I will be able to rename the directories within the
    # repository without losing revision histories.  When that
    # happens, I'll rename the 'lib' driectory to 'privlib'.

    PMLIBDIRS      => [ 'POE' ],
  );

1;
