#!/usr/bin/perl

use strict;
use ExtUtils::MakeMaker;
use Config;

eval "use 5.005_03";
if ($@) {
  warn( "\n",
        "===============================================================\n",
        "\n",
        "Perl 5.005_03 or later is preferred, and versions before it are\n",
        "deprecated.  Try installing POE with a newer version of Perl to\n",
        "see what you're missing. :)\n",
        "\n",
        "===============================================================\n",
        "\n",
      );

  require "./lib/Makefile-5004.pm";
}
else {
  if( (defined $Config{useithreads}) && ($Config{useithreads} eq 'define') ) {
    warn( "\n",
          "================================================================\n",
          "\n",
          "Your perl seems to be built with ithreads activated.  As of this\n",
          "writing (Sep 22 2002), ithreads has a rather icky bug where\n",
          "constant values may randomly change.  This can cause sporadic\n",
          "errors in POE, which makes heavy use of constants.\n",
          "\n",
          "We recommend rebuilding perl without ithreads until the problem\n",
          "is resolved.  The issue is described in detail and tracked at\n",
          "http://bugs6.perl.org/rt2/Ticket/Display.html?id=15654\n",
          "\n",
          "================================================================\n",
          "\n",
        );
    sleep 5;
    print "Continuing with configure process...\n";
  }
  require "./lib/Makefile-5005.pm";
}

0;
