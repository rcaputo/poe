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

  require "./mylib/Makefile-5004.pm";
}
else {
  require "./mylib/Makefile-5005.pm";
}

0;
