#!/usr/bin/perl
# $Id$

use strict;

use lib qw(./mylib);
use ExtUtils::MakeMaker;

# Switch to default behavior if STDIN isn't a tty.
unless (-t STDIN) {
  warn(
    "\n",
    "======================================================================\n",
    "\n",
    "Standard input is not a terminal/console.  Reverting to --default\n",
    "behavior to avoid the prompts.\n",
    "\n",
    "======================================================================\n",
    "\n",
  );
  push @ARGV, "--default";
}

eval "require ExtUtils::AutoInstall";
if ($@) {
  warn( "\n",
        "==================================================================\n",
        "\n",
        "POE's installer magic requires ExtUtils::AutoInstall.  POE comes\n",
        "with an older version, but it will not be installed.  You should\n",
        "install the most recent ExtUtils::AutoInstall at your convenience.\n",
        "\n",
        "==================================================================\n",
        "\n",
      );
  eval "require './mylib/ExtUtils/AutoInstall.pm'";
  die if $@;
}

unless (grep /^--default$/, @ARGV) {
  print( "\n",
         "=================================================================\n",
         "\n",
         "If the prompts are annoying, they can be bypassed by running\n",
         "\t$^X $0 --default\n",
         "\n",
         "Only the necessary modules will be installed by default.\n",
         "\n",
         "=================================================================\n",
         "\n",
       );
}

ExtUtils::AutoInstall->import
  ( -version => '0.50',
    -core => [
        Carp                 => '',
        Exporter             => '',
        IO                   => '',
        POSIX                => '',
        Socket               => '',
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
        'HTTP::Status'   => '',
        'HTTP::Request'  => '',
        'HTTP::Date'     => '',
        'HTTP::Response' => '',
        'URI'            => '',
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

# Touch CHANGES so it exists.
open(CHANGES, ">>CHANGES") and close CHANGES;

sub MY::postamble {
  return ExtUtils::AutoInstall::postamble() .
    <<EOF;
reportupload: poe_report.xml
	$^X mylib/reportupload.pl

uploadreport: poe_report.xml
	$^X mylib/reportupload.pl

testreport: poe_report.xml

poe_report.xml: Makefile
	$^X mylib/testreport.pl

ppmdist: pm_to_blib
	\$(TAR) --exclude '*/man[13]*' -cvf \\
		\$(DISTVNAME)-win32ppd.tar blib
	\$(COMPRESS) \$(DISTVNAME)-win32ppd.tar

ppddist: ppmdist
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
      'tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES'
    ),
  },

  test           => { TESTS => 't/*/*.t t/*.t' },

  clean          => {
      FILES => 'poe_report.xml test-output.err coverage.report',
  },

  # More for META.yml than anything.
  PREREQ_PM      => {
    'Test::More'         => 0,
    'Filter::Util::Call' => 1.04,
  },
);

1;
