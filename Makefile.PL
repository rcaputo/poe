# $Id$

use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile
  (
   'NAME'         => 'POE',
   'VERSION_FROM' => 'POE.pm',
   'dist'         => { 'COMPRESS' => 'gzip -9',
                       'SUFFIX'   => 'gz',
                     },
  );
