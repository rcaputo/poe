#!/usr/bin/perl

use strict;
use ExtUtils::MakeMaker;

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
  require "./lib/Makefile-5005.pm";
}

0;
