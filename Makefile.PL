#!/usr/bin/perl

use strict;
use ExtUtils::MakeMaker;
use Config;

my $prompt = qq|
POE's test suite requires a functional network.
However, we can skip those tests requiring network
access if you would like.

Would you like to skip this network tests?

|;

my $ret = prompt($prompt."(Any other text than Y or y will be taken as a no)","n");

my $marker = 'run_network_tests';

if($ret =~ /^Y$/i) {
    unlink $marker if $marker;
} else {
    open(TOUCH,"+>$marker") and close TOUCH;
}

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
