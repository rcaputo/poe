#!/usr/bin/perl -w
# vim: filetype=perl

# Randal Schwartz reported that die() within _stop causes an infinite
# loop.  He's right.  This tests rt.cpan.org ticket 19908.

# perl-5.6.x on Win32 does not support alarm()
BEGIN {
  if ( $^O eq 'MSWin32' and $] < 5.008 ) {
    print "1..0 # Skip perl-5.6.x on $^O does not support alarm()";
    exit();
  }
}

use POE;
use Test::More tests => 3;

$SIG{ALRM} = sub { exit };
alarm(5);

my $stop_count = 0;

POE::Session->create(
  inline_states => {
    _start => sub {
      pass("started");
    },
    _stop => sub {
      $stop_count++;
      die "stop\n";
    },
  }
);

eval { POE::Kernel->run() };
$SIG{ALRM} = "IGNORE";
ok($@ eq "stop\n", "stopped due to a 'stop' exception (in _stop)");
ok($stop_count == 1, "stopped after one _stop");
