#!/usr/bin/perl

use strict;
use ExtUtils::MakeMaker;
use Config;

eval "use 5.005_03";
if ($@) {
  warn( "\n",
        "================================================================\n",
        "\n",
        "Perl 5.005_03 or later is preferred, and versions before it may\n",
        "be deprecated in the future.  Try installing POE with a newer\n",
        "version of Perl to see what you're missing. :)\n",
        "\n",
        "================================================================\n",
        "\n",
      );

  require "./lib/Makefile-5004.pm";
}
else {
    if( (defined $Config{useithreads}) && ($Config{useithreads} eq 'define') ) {
        warn( "\n",
            "================================================================\n",
            "\n",
            "You appear to using a perl compiled with ithreads activated.\n",
            "As of the time of writing (Sep 22 2002), ithreads has a rather\n",
            "icky bug related to constants.  This bug causes POE to exhibit\n",
            "some rather strange behavior or to simply not function.\n",
            "\n",
            "It is advised that you do not use POE with an ithreads enabled\n",
            "perl. Sorry for any inconvenience.\n",
            "\n",
            "For more information on this issue and to track its status\n",
            "please see http://bugs6.perl.org/rt2/Ticket/Display.html?id=15654\n",
            "\n",
            "================================================================\n",
            "\n",
        );
        sleep 2;
        print "Continuing with configure process...\n";
    }
    require "./lib/Makefile-5005.pm";
}

0;
