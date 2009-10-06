# vim: ts=2 sw=2 expandtab

# Test a case that Yuval Kogman ran into.  Decrementing a reference
# count would immediately trigger a GC test.  During _start, that
# means a session might be GC'd before _start's handler returned.
# Fatal hilarity would ensue.

use warnings;
use strict;

use Test::More tests => 5;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 0 }

use POE;

my $sigidle = 0;

# The "bystander" session is kept alive solely by its extra reference
# count.  It should be stopped when the "refcount" session destructs.
# This is determined by comparing the _stop time vs. SIGIDLE delivery.
# If _stop is first, then the bystander was reaped correctly.

my $bystander_id = POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->refcount_increment( $_[SESSION]->ID, "just hold me");
    },
    _stop => sub {
      ok(
        !$sigidle,
        "bystander stopped before sigidle"
      );
    },
  },
)->ID;

# The "sigidle" session watches for SIGIDLE and sets a flag.  If the
# bystander is reaped after SIGIDLE, it means that the refcount
# session did not trigger its destruction.

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->sig( IDLE => 'got_sigidle' );
      $_[KERNEL]->alias_set("stayin_alive");
    },
    got_sigidle => sub {
      $sigidle++;
      pass("got sigidle");
    },
    _stop => sub {
      pass("sigidle session is allowed to stop");
    },
  },
);

# The "refcount" session attempts to trigger its own untimely
# destruction by incrementing and decrementing a reference count.  If
# it succeeds in killing itself off early, then its "do_something"
# event will cause a fatal runtime error when ASSERT_DEFAULT is on.
#
# As part of _stop, it decrements the extra reference on the bystander
# session, triggering its destruction before SIGIDLE.  If there's a
# problem, SIGIDLE will arrive first---because POE::Kernel has a
# refcount of 0 but the session still exists.

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->refcount_increment($_[SESSION]->ID, "just hold me");
      $_[KERNEL]->refcount_decrement($_[SESSION]->ID, "just hold me");
      $_[KERNEL]->yield("do_something");
    },
    do_something => sub {
      pass("refcount session is allowed to run");
    },
    _stop => sub {
      pass("refcount session is allowed to stop");
      $_[KERNEL]->refcount_decrement($bystander_id, "just hold me");
    },
  },
);

POE::Kernel->run();

1;
