#!/usr/bin/perl
# $Id$

use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile
  ( NAME         => 'POE',
    AUTHOR       => 'Rocco Caputo <troc@netrus.net>',
    ABSTRACT     => 'Event driven state machines and I/O abstractions.',
    VERSION_FROM => 'POE.pm',
    dist         => { 'COMPRESS' => 'gzip -9',
                      'SUFFIX'   => 'gz',
                    },
    PREREQ_PM    => { Carp      => 0,
                      Exporter  => 0,
                      IO        => 0,
                      POSIX     => 0,
                      Socket    => 0,
                      Filter    => 1.18,
                    },
  );

__END__

  DIR
    Ref to array of subdirectories containing Makefile.PLs e.g. [ 'sdbm' ]
    in ext/SDBM_File
