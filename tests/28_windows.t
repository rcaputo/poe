#!/usr/bin/perl -w
# $Id$

# Tests various signals using POE's stock signal handlers.  These are
# plain Perl signals, so mileage may vary.

use strict;
use lib qw(./lib ../lib .. .);
use TestSetup;

BEGIN {
  test_setup(0, "Windows tests aren't necessary on $^O")
    if $^O eq 'MacOS';
};

test_setup(1);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
BEGIN { open STDERR, ">./test-output.err" or die $!; }

use POE;

# POE::Kernel in version 0.19 assumed that SIGCHLD on Windows would
# always return negative PIDs.  This was only true for pseudo
# processes created by fork().  Ted Suzman pointed out that real
# processes, such as those created by open("foo|"), have positive
# PIDs, so the internal inconsistency checks in POE were bogus.  This
# test generates a positive PID and ensures that it's not treated as
# an error.

POE::Session->create
  ( inline_states =>
    { _start => sub {
        $_[KERNEL]->sig(CHLD => "child_handler");
        $_[KERNEL]->delay(timeout => 5);
        open(FOO, "echo foo > nul:|") or die $!;
        open(FOO, "echo foo > nul:|") or die $!;
        my @x = <FOO>;
      },
      child_handler => sub {
        ok(1);
        $_[KERNEL]->delay(timeout => undef);
      },
      _stop => sub { },
      timeout => sub {
        not_ok(1);
      },
    }
  );

$poe_kernel->run();
results();
close FOO;
unlink "nul:";
