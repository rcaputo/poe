#!/usr/bin/perl
# $Id$

use strict;

use lib qw(./mylib);

use ExtUtils::MakeMaker;

eval "require ExtUtils::AutoInstall";
if ($@) {
  warn(
    "\n",
    "====================================================================\n",
    "\n",
    "POE's installer magic requires ExtUtils::AutoInstall.  POE comes\n",
    "with an older version, but it will not be installed.  You should\n",
    "install the most recent ExtUtils::AutoInstall at your convenience.\n",
    "\n",
    "====================================================================\n",
    "\n",
  );
  eval "require './mylib/ExtUtils/AutoInstall.pm'";
  die if $@;
}

# TODO - Combine the -core requirements here, and in PREREQ_PM below,
# into one has they can both share.

ExtUtils::AutoInstall->import(
  -version => '0.50',
  -core => [
    "Carp"               => 0,
    "Exporter"           => 0,
    "IO"                 => 1.20,
    "POSIX"              => 1.02,
    "Socket"             => 1.7,
    "Filter::Util::Call" => 1.06,
    "Test::More"         => 0.47,
    "File::Spec"         => 0.87,
    "Errno"              => 1.09,
  ],
  "Recommended modules to increase timer/alarm/delay accuracy." => [
      -default      => 0,
      'Time::HiRes' => '1.59',
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
);

# Generate dynamic test files.

system($^X, "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

# Touch generated files so they exist.
open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

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
    : ( AUTHOR   => 'Rocco Caputo <rcaputo@cpan.org>',
        ABSTRACT => 'A highly portable networking and multitasking framework.',
      )
  ),

  VERSION_FROM   => 'lib/POE.pm',
  dist           => {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
    PREOP    => (
      './mylib/cvs-log.perl | ' .
      '/usr/bin/tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES; ' .
      "$^X Build.PL; " .
      './Build distmeta; ' .
      '/bin/cp -f ./META.yml ./$(DISTNAME)-$(VERSION)/META.yml'
    ),
  },

  clean          => {
    FILES => (
      "coverage.report " .
      "poe_report.xml " .
      "run_network_tests " .
      "tests/20_resources/10_perl/* " .
      "tests/20_resources/20_xs/* " .
      "tests/30_loops/10_select/* " .
      "tests/30_loops/20_poll/* " .
      "tests/30_loops/30_event/* " .
      "tests/30_loops/40_gtk/* " .
      "tests/30_loops/50_tk/* " .
      "test-output.err "
    ),
  },

  # More for META.yml than anything.
  PL_FILES       => { },
  NO_META        => 1,
  PREREQ_PM      => {
    "Carp"               => 0,
    "Exporter"           => 0,
    "IO"                 => 1.20,
    "POSIX"              => 1.02,
    "Socket"             => 1.7,
    "Filter::Util::Call" => 1.06,
    "Test::More"         => 0.50,
    "File::Spec"         => 3.01,
    "Errno"              => 1.09,
  },
);

1;
