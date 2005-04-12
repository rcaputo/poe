#!/usr/bin/perl
# $Id$

use strict;

use ExtUtils::MakeMaker;

use lib qw(./mylib);
use PoeBuildInfo qw(
  CLEAN_FILES
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  RECOMMENDED_TIME_HIRES
);

### Touch files that will be generated at "make dist" time.
### ExtUtils::MakeMaker and Module::Build will complain about them if
### they aren't present now.

open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

### Ensure ExtUtils::AutoInstall is installed.

eval "require ExtUtils::AutoInstall";
if ($@) {
  warn(
    "\n",
    "====================================================================\n",
    "\n",
    "POE's installer magic requires ExtUtils::AutoInstall.  POE comes\n",
    "with its own version, but it is usually out of date and won't be\n",
    "installed.  You should install the most recent version at your\n",
    "earliest convenience.\n",
    "\n",
    "====================================================================\n",
    "\n",
  );
  eval "require './mylib/ExtUtils/AutoInstall.pm'";
  die if $@;
}

### Some things we can do on Windows.

my @windows_options;
if ($^O eq "MSWin32") {
  @windows_options = (
    "Optional modules for Windows POE::Wheel::Run support." => [
        -default => 0,
        'Win32API::File'  => '0.05',
        'Win32::Console'  => '0.031',
    ],
  );
}

### Prompt for additional modules.

ExtUtils::AutoInstall->import(
  -version => '0.50',
  -core => [ CORE_REQUIREMENTS ],
  "Recommended modules to increase timer/alarm/delay accuracy." => [
      -default      => 0,
      RECOMMENDED_TIME_HIRES,
  ],
  "Optional modules to speed up large-scale clients/servers." => [
      -default   => 0,
      'IO::Poll' => 0.01,
  ],
  "Optional modules for IPv6 support." => [
      -default  => 0,
      'Socket6' => 0.14,
  ],
  "Optional modules for controlling full-screen programs (e.g. vi)." => [
      -default  => 0,
      'IO::Pty' => '1.02',
  ],
  "Optional modules for marshaling/serializing data." => [
      -default         => 0,
      'Storable'       => '2.12',
      'Compress::Zlib' => '1.33',
  ],
  "Optional modules for web applications (client & server)." => [
      -default => 0,
      'LWP'            => '5.79',
      'URI'            => '1.30',
  ],
  "Optional modules for Curses text interfaces." => [
      -default => 0,
      'Curses' => '1.08',
  ],
  "Optional modules for console (command line) interfaces." => [
      -default        => 0,
      'Term::ReadKey' => '2.21',
      'Term::Cap'     => '1.09',
  ],
  "Optional modules for Gtk+ graphical interfaces." => [
      -default => 0,
      'Gtk'    => '0.7009',
  ],
  "Optional modules for Tk graphical interfaces." => [
      -default => 0,
      'Tk'     => '800.027',
  ],
  "Optional modules for Event.pm support." => [
      -default => 0,
      'Event'  => '1.00',
  ],
  @windows_options,
);

### Generate dynamic test files.

system($^X, "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

### Generate Makefile.PL.

sub MY::postamble {
  return ExtUtils::AutoInstall::postamble() .
    <<EOF;
reportupload: poe_report.xml
\cI$^X mylib/reportupload.pl

uploadreport: poe_report.xml
\cI$^X mylib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
\cI$^X mylib/testreport.pl

ppmdist: pm_to_blib
\cI\$(TAR) --exclude '*/man[13]*' -cvf \\
\cI\cI\$(DISTVNAME)-win32ppd.tar blib
\cI\$(COMPRESS) \$(DISTVNAME)-win32ppd.tar

ppddist: ppmdist

coverage: Makefile
\cI$^X mylib/coverage.perl

cover: coverage
EOF
}

WriteMakefile(
  NAME           => 'POE',

  (
    ($^O eq 'MacOS')
    ? ()
    : ( AUTHOR   => DIST_AUTHOR,
        ABSTRACT => DIST_ABSTRACT,
      )
  ),

  VERSION_FROM   => 'lib/POE.pm',
  dist           => {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
    PREOP    => (
      './mylib/cvs-log.perl | ' .
      '/usr/bin/tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES; ' .
      "$^X mylib/gen-meta.perl; " .
      '/bin/cp -f ./META.yml ./$(DISTNAME)-$(VERSION)/META.yml'
    ),
  },

  clean => {
    FILES => CLEAN_FILES,
  },

  # More for META.yml than anything.
  PL_FILES       => { },
  NO_META        => 1,
  PREREQ_PM      => { CORE_REQUIREMENTS },
);

1;
