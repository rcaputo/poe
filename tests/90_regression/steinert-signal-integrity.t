#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl

# Jonathan Steinert produced a patch to fix POE::Wheel destruction
# timing, and possibly other things, when they're passed as arguments
# to an event handler.  It didn't take into consideration a subtle and
# obscure aspect of recursive signal dispatch.  This regression test
# makes sure nested signal dispatches receive the proper parameters.

use strict;

sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;
use POE::Wheel::ReadWrite;
use POE::Pipe::OneWay;

use Test::More tests => 2;

my $session_count = 0;

sub start_session {
  $session_count++;
  POE::Session->create(
    inline_states => {
      _start     => \&setup,
      got_signal => \&handle_signal,
      _stop      => sub { },
    }
  );
}

start_session();
$poe_kernel->signal($poe_kernel, MOO => 99);
POE::Kernel->run();
exit;

sub setup {
  start_session() if $session_count < 2;
  $_[KERNEL]->sig(MOO => "got_signal");
  $_[KERNEL]->delay(timed_out => 2);
}

sub handle_signal {
  ok(
    ($_[ARG0] eq "MOO") &&
    ($_[ARG1] == 99),
    "signal parameters: ('$_[ARG0]' eq 'MOO', $_[ARG1] == 99)"
  );
}
