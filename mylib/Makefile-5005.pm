#!/usr/bin/perl
# $Id$

use strict;

use ExtUtils::MakeMaker;

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
  eval "require './lib/AutoInstall.pm'";
  die if $@;
}

ExtUtils::AutoInstall->import
  ( -version => '0.29',
    -core => [
        Carp     => '',
        Exporter => '',
        IO       => '',
        POSIX    => '',
        Socket   => '',
        'Filter::Util::Call' => 1.04,
    ],
    'Optional Sub-Second Timer Support' => [
        -default      => 0,
        'Time::HiRes' => '',
    ],
    'Optional Full-Screen Child Process Support' => [
        -default  => 0,
        'IO::Pty' => '',
    ],
    'Optional Serialized Data Transfer Support' => [
        -default   => 0,
        'Storable' => '',
        'Compress::Zlib' => '',
    ],
    'Optional Web Server Support' => [
        -default => 0,
        'HTTP::Status'   => '',
        'HTTP::Request'  => '',
        'HTTP::Date'     => '',
        'HTTP::Response' => '',
        'URI'            => '',
    ],
    'Optional Gtk Support' => [
        -default => 0,
        -tests => [ qw(t/21_gtk.t) ],
        'Gtk'  => '',
    ],
    'Optional Tk Support' => [
        -default => 0,
        -tests => [ qw(t/06_tk.t) ],
        'Tk'   => '800.021',
    ],
    'Optional Event.pm Support' => [
        -default => 0,
        -tests  => [ qw(t/07_event.t t/12_signals_ev.t) ],
        'Event' => '',
    ],
);

# Touch CHANGES so it exists.
# open(CHANGES, ">>CHANGES") and close CHANGES;

WriteMakefile
  ( NAME           => 'POE',

    ( ($^O eq 'MacOS')
      ? ()
      : ( AUTHOR   => 'Rocco Caputo <rcaputo@cpan.org>',
          ABSTRACT => 'A networking/multitasking framework for Perl.',
        )
    ),

    VERSION_FROM   => 'POE.pm',
    dist           =>
    { COMPRESS => 'gzip -9f',
      SUFFIX   => 'gz',
    # PREOP    => qq(cvs2cl.pl -l "-d'a year ago<'" --utc --file CHANGES),
    },

    PMLIBDIRS      => [ 'POE' ],
  );

1;
