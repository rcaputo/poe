#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Test the ASSERT_USAGE code in POE::Kernel.  This involves a lot of
# dying.

use strict;
use lib qw(./mylib);

use Test::More tests => 22;

BEGIN { delete $ENV{POE_ASSERT_USAGE}; }
sub POE::Kernel::ASSERT_RETVALS () { 1 }
BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

BEGIN { use_ok("POE") }

# Disable any "didn't call run" warnings.

POE::Kernel->run();

# Strange return values.

eval { $poe_kernel->alarm(undef) };
ok(
  $@ && $@ =~ /invalid parameter to alarm/,
  "alarm with undefined event name"
);

eval { $poe_kernel->alarm_add(undef) };
ok(
  $@ && $@ =~ /invalid parameter to alarm_add/,
  "alarm_add with undefined event name"
);

eval { $poe_kernel->delay(undef) };
ok(
  $@ && $@ =~ /invalid parameter to delay/,
  "delay with undefined event name"
);

eval { $poe_kernel->delay_add(undef) };
ok(
  $@ && $@ =~ /invalid parameter to delay_add/,
  "delay_add with undefined event name"
);

eval { $poe_kernel->ID_id_to_session(999) };
ok(
  $@ && $@ =~ /ID does not exist/,
  "ID_id_to_session with unknown ID"
);

eval { $poe_kernel->ID_session_to_id(999) };
ok(
  $@ && $@ =~ /session \(999\) does not exist/,
  "ID_session_to_id with unknown session"
);

eval { $poe_kernel->refcount_increment(999) };
ok(
  $@ && $@ =~ /session id 999 does not exist/,
  "refcount_increment with unknown session ID"
);

eval { $poe_kernel->refcount_decrement(999) };
ok(
  $@ && $@ =~ /session id 999 does not exist/,
  "refcount_decrement with unknown session ID"
);

eval { $poe_kernel->state(moo => sub { } ) };
ok(
  $@ && $@ =~ /session \(.*?\) does not exist/,
  "state with nonexistent active session"
);

# Strange usage.

eval { $poe_kernel->alarm_set(undef) };
ok(
  $@ && $@ =~ /undefined event name in alarm_set/,
  "event undefined in alarm_set"
);

eval { $poe_kernel->alarm_set(moo => undef) };
ok(
  $@ && $@ =~ /undefined time in alarm_set/,
  "time undefined in alarm_set"
);

eval { $poe_kernel->alarm_remove(undef) };
ok(
  $@ && $@ =~ /undefined alarm id in alarm_remove/,
  "alarm ID undefined in alarm_remove"
);

eval { $poe_kernel->alarm_adjust(undef) };
ok(
  $@ && $@ =~ /undefined alarm id in alarm_adjust/,
  "alarm ID undefined in alarm_adjust"
);

eval { $poe_kernel->alarm_adjust(moo => undef) };
ok(
  $@ && $@ =~ /undefined alarm delta in alarm_adjust/,
  "alarm time undefined in alarm_adjust"
);

eval { $poe_kernel->delay_set(undef) };
ok(
  $@ && $@ =~ /undefined event name in delay_set/,
  "event name undefined in delay_set"
);

eval { $poe_kernel->delay_set(moo => undef) };
ok(
  $@ && $@ =~ /undefined seconds in delay_set/,
  "seconds undefined in delay_set"
);

eval { $poe_kernel->delay_adjust(undef) };
ok(
  $@ && $@ =~ /undefined delay id in delay_adjust/,
  "delay ID undefined in delay_adjust"
);

eval { $poe_kernel->delay_adjust(moo => undef) };
ok(
  $@ && $@ =~ /undefined delay seconds in delay_adjust/,
  "delay seconds undefined in delay_adjust"
);

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->alias_set("moo");
    }
  }
);

POE::Session->create(
  inline_states => {
    _start => sub {
      eval { $_[KERNEL]->alias_set("moo") };
      ok(
        $@ && $@ =~ /alias 'moo' is in use by another session/,
        "alias already in use"
      );

      eval { $_[KERNEL]->alias_remove("moo") };
      ok(
        $@ && $@ =~ /alias does not belong to current session/,
        "alias belongs to another session"
      );
    }
  }
);

eval { $poe_kernel->alias_remove("narf") };
ok(
  $@ && $@ =~ /alias does not exist/,
  "alias does not exist"
);

exit 0;
