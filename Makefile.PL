#!/usr/bin/perl

use strict;
use ExtUtils::MakeMaker;
use Config;

# Switch to default behavior if STDIN isn't a tty.

unless (-t STDIN) {
  warn(
    "\n",
    "====================================================================\n",
    "\n",
    "Assuming --default because standard input is not a terminal.\n",
    "\n",
    "====================================================================\n",
    "\n",
  );
  push @ARGV, "--default";
}

# Remind the user she can use --default.

unless (grep /^--default$/, @ARGV) {
  warn(
    "\n",
    "====================================================================\n",
    "\n",
    "Prompts may be bypassed by running:\n",
    "   $^X $0 --default\n",
     "\n",
    "Only necessary modules will be installed by default.\n",
    "\n",
    "====================================================================\n",
    "\n",
  );
}

# Should we skip the network tests?

my $prompt = qq|
POE's test suite requires a functional network.
However, we can skip those tests requiring network
access if you would like.

Would you like to skip the network tests?

|;

$prompt .= "(Any text other than Y or y will be taken as a no)";

my $ret = "n";
if (grep /^--default$/, @ARGV) {
  print $prompt, " [n] n\n\n";
}
else {
  $ret = prompt($prompt, "n");
}

my $marker = 'run_network_tests';

if($ret =~ /^Y$/i) {
    unlink $marker if $marker;
} else {
    open(TOUCH,"+>$marker") and close TOUCH;
}

print "\n";

# Which kind of makefile should we build?

if ($] < 5.005004) {
  warn(
    "\n",
    "===============================================================\n",
    "\n",
    "Please upgrade Perl to avoid lapses in support.  Perl 5.005_04\n",
    "or newer is preferred.  Support for older versions will be\n",
    "phased out in the future.\n",
    "\n",
    "Thank you.\n",
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
