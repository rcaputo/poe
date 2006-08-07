#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl

# Randal Schwartz reported that die() within _stop causes an infinite
# loop.  He's right.  This tests rt.cpan.org ticket 19908.

use POE;
use Test::More tests => 2;

$SIG{ALRM} = sub { exit };
alarm(5);

POE::Session->create(
  inline_states => {
    _start => sub {
      pass("started");
    },
    _stop => sub {
      die "stop";
    },
  }
);

POE::Kernel->run();
pass("stopped");
