#!/usr/bin/perl
# $Id$

use ExtUtils::MakeMaker;

# Add a new target.

sub MY::test {
  package MY;
  "\ntest ::\n\t\$(FULLPERL) ./lib/deptest.perl\n" . shift->SUPER::test(@_);
}

# See lib/ExtUtils/MakeMaker.pm for details of how to influence the
# contents of the Makefile that is written.

WriteMakefile
  ( NAME           => 'POE',
    AUTHOR         => 'Rocco Caputo <troc+poe@netrus.net>',
    ABSTRACT       => 'Event driven state machines and I/O abstractions.',
    VERSION_FROM   => 'POE.pm',
    dist           => { 'COMPRESS' => 'gzip -9f',
                        'SUFFIX'   => 'gz',
                      },
    PREREQ_PM      => { Carp               => 0,
                        Exporter           => 0,
                        IO                 => 0,
                        POSIX              => 0,
                        Socket             => 0,
                        Filter::Util::Call => 1.04,
                      },
    PERL_MALLOC_OK => 'true',
  );

exit 0;
