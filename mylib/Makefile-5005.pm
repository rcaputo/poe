#!/usr/bin/perl
# $Id$

use strict;

use lib qw(./mylib);

use ExtUtils::MakeMaker;
use File::Find;
use File::Spec;

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

ExtUtils::AutoInstall->import(
  -version => '0.50',
  -core => [
      Carp                 => '',
      Exporter             => '',
      IO                   => '',
      POSIX                => '',
      Socket               => '',
      'File::Spec'         => '',
      'Test::More'         => '',
      'Filter::Util::Call' => 1.04,
  ],
  "Recommended modules to increase timer/alarm/delay accuracy." => [
      -default      => 0,
      'Time::HiRes' => '',
  ],
  "Optional modules to speed up large-scale clients/servers." => [
      -default   => 0,
      -tests     => [ qw(t/27_poll.t) ],
      'IO::Poll' => 0.05,
  ],
  "Optional modules for IPv6 support." => [
      -default  => 0,
      -tests    => [ qw(t/29_sockfact6.t) ],
      'Socket6' => 0.11,
  ],
  "Optional modules for controlling full-screen programs (e.g. vi)." => [
      -default  => 0,
      'IO::Pty' => '1.02',
  ],
  "Optional modules for marshaling/serializing data." => [
      -default         => 0,
      'Storable'       => '',
      'Compress::Zlib' => '',
  ],
  "Optional modules for web applications (client & server)." => [
      -default => 0,
      -tests => [ qw(t/30_filter_httpd.t) ],
      'HTTP::Status'   => '1.28',
      'HTTP::Request'  => '1.34',
      'HTTP::Date'     => '1.46',
      'HTTP::Response' => '1.41',
      'URI'            => '1.27',
  ],
  "Optional modules for Curses text interfaces." => [
      -default => 0,
      'Curses' => '',
  ],
  "Optional modules for console (command line) interfaces." => [
      -default        => 0,
      'Term::ReadKey' => '',
      'Term::Cap'     => '',
  ],
  "Optional modules for Gtk+ graphical interfaces." => [
      -default => 0,
      -tests   => [ qw(t/21_gtk.t) ],
      'Gtk'    => '',
  ],
  "Optional modules for Tk graphical interfaces." => [
      -default => 0,
      -tests   => [ qw(t/06_tk.t) ],
      'Tk'     => '800.021',
  ],
  "Optional modules for Event.pm support." => [
      -default => 0,
      -tests   => [ qw(t/07_event.t t/12_signals_ev.t) ],
      'Event'  => '',
  ],
);

# Generate dynamic test files.

system($^X, "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

# Build a list of all the tests to run.

my @tests;

find(
  sub {
    return unless /\.t$/;
    push @tests, File::Spec->catfile($File::Find::dir,$_);
  },
  't/',
);

my $test_str = join " ", sort @tests;

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
        ABSTRACT => 'A portable networking/multitasking framework for Perl.',
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

  test           => { TESTS => $test_str },

  clean          => {
    FILES => (
      "coverage.report " .
      "poe_report.xml " .
      "run_network_tests " .
      "t/20_resources/10_perl/* " .
      "t/20_resources/20_xs/* " .
      "t/30_loops/10_select/* " .
      "t/30_loops/20_poll/* " .
      "t/30_loops/30_event/* " .
      "t/30_loops/40_gtk/* " .
      "t/30_loops/50_tk/* " .
      "test-output.err "
    ),
  },

  # More for META.yml than anything.
  PL_FILES       => { },
  NO_META        => 1,
  PREREQ_PM      => {
    'Test::More'         => 0,
    'Filter::Util::Call' => 1.04,
  },
);

1;
