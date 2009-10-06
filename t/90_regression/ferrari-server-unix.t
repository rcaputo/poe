#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Test case supplied by Martin Ferrari as part of rt.cpan.org bug
# 11262 (Debian bug 292526).  Ensures that a previous warning will not
# be thrown when using UNIX sockets with Server::TCP.

use strict;

BEGIN {
  my $error;
  unless (-f 'run_network_tests') {
    $error = "Network access (and permission) required to run this test";
  }
  elsif ($^O eq "MSWin32" or $^O eq "MacOS") {
    $error = "$^O does not support UNIX sockets";
  }

  if ($error) {
    print "1..0 # Skip $error\n";
    exit;
  }
}

use POE;
use POE::Component::Server::TCP;
use Socket qw/AF_UNIX/;
use Test::More tests => 1;

unless($ARGV[0] && $ARGV[0] eq "test") {
  my $out = `$^X "$0" test 2>&1 >/dev/null`;
  chomp($out);
  isnt($out, "UNIX socket should not throw a warning");
  exit;
}

my $sock = "./testsocket.$$";
unlink($sock);

POE::Component::Server::TCP->new(
  Port        => 0,
  Address     => $sock,
  Domain      => AF_UNIX,
  ClientInput => sub {},
  Alias       => "testserver",
);

POE::Kernel->post(testserver => "shutdown");

POE::Kernel->run();
unlink($sock);

exit;
