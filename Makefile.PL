#!/usr/bin/perl

use strict;
use ExtUtils::MakeMaker;

warn $];

eval "use 5.005_03";
if ($@) {
  warn( "\n",
        "================================================================\n",
        "\n",
        "Perl 5.004 support is deprecated and will be disappearing soon.\n",
        "Please upgrade to 5.005_03 or newer.  Try installing POE with a\n",
        "newer version of Perl to see what you're missing. :)\n",
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
