#!/usr/bin/perl -w
# vim: filetype=perl

# Tests various signals using POE's stock signal handlers.  These are
# plain Perl signals, so mileage may vary.

use strict;
use lib qw(./mylib ../mylib);

use Test::More;

BEGIN {
  plan(skip_all => "Windows tests aren't necessary on $^O") if $^O eq "MacOS";
};

plan tests => 2;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

# POE::Kernel in version 0.19 assumed that SIGCHLD on Windows would
# always return negative PIDs.  This was only true for pseudo
# processes created by fork().  Ted Suzman pointed out that real
# processes, such as those created by open("foo|"), have positive
# PIDs, so the internal inconsistency checks in POE were bogus.  This
# test generates a positive PID and ensures that it's not treated as
# an error.

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->sig(CHLD => "child_handler");
      $_[KERNEL]->delay(timeout => 5);
      open(FOO, "echo foo > nul:|") or die $!;
      open(FOO, "echo foo > nul:|") or die $!;
      my @x = <FOO>;
    },
    child_handler => sub {
      pass("handled real SIGCHLD");
      $_[KERNEL]->delay(timeout => undef);
      $_[KERNEL]->sig(CHLD => undef);
    },
    _stop => sub { },
    timeout => sub {
      fail("handled real SIGCHLD");
      $_[KERNEL]->sig(CHLD => undef);
    },
  }
);

POE::Kernel->run();

close FOO;
unlink "nul:";

pass("run() returned successfully");
