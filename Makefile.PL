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
    PREREQ_PM    => { Carp           => 0,
                      Exporter       => 0,
                      HTTP::Request  => 1.24,
                      HTTP::Response => 1.32,
                      HTTP::Status   => 1.24,
                      IO             => 1.20,
                      POSIX          => 1.02,
                      Socket         => 1.7,
                      Storable       => 0.603,
                      Time::HiRes    => 1.19,
                      URI::URL       => 5.01,
                    },
  );

__END__

  DIR
    Ref to array of subdirectories containing Makefile.PLs e.g. [ 'sdbm' ]
    in ext/SDBM_File
