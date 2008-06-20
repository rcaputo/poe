#!/usr/bin/perl -w

# This file contains tests for the _internal_ POE::Kernel interface
# i.e. the interface exposed to POE::Session, POE::Resources::* etc

use strict;
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

# Tests _trap_death and _release_death indirectly (as well as directly when we
# test _croak etc) by checking that POE doesn't leave $SIG{__WARN__}
# and $SIG{__DIE__} altered.
my ($initial__die__, $initial__warn__, $last_exception);
BEGIN {
  *CORE::GLOBAL::die = sub {
    $last_exception = "die: @_";
    CORE::die(@_);
  };
  *CORE::GLOBAL::warn = sub {
    $last_exception = "warn: @_";
    CORE::warn(@_);
  };

  # reload Carp so it sees the CORE::GLOBAL overrides
  delete $INC{"Carp.pm"};
  require Symbol;
  Symbol::delete_package("Carp");
  require Carp;
}

use Test::More tests => 12;

BEGIN { use_ok("POE::Kernel"); }

# The expected size of the queue when the kernel is idle (without any
# user generated/requested events)
{
  my $base_size = $poe_kernel->_idle_queue_size();
  $poe_kernel->_idle_queue_grow();
  is( $poe_kernel->_idle_queue_size(), $base_size + 1,
    "growing idle queue");
  $poe_kernel->_idle_queue_grow();
  is( $poe_kernel->_idle_queue_size(), $base_size + 2,
    "growing idle queue (2)");
  $poe_kernel->_idle_queue_shrink();
  is( $poe_kernel->_idle_queue_size(), $base_size + 1,
    "shrinking idle queue");
  $poe_kernel->_idle_queue_shrink();
  is( $poe_kernel->_idle_queue_size(), $base_size,
    "shrinking idle queue (2)");
}

{
  $last_exception = '';
  eval { POE::Kernel::_trap("testing _trap") };
  ok($last_exception =~ /^die:/, "_trap confessed");
}
{
  $last_exception = '';
  eval { POE::Kernel::_croak("testing _croak") };
  ok($last_exception =~ /^die:/, "_croak croaked");
}
{
  $last_exception = '';
  eval { POE::Kernel::_confess("testing _confess") };
  ok($last_exception =~ /^die:/, "_confess confessed");
}
{
  $last_exception = '';
  eval { POE::Kernel::_cluck("testing _cluck") };
  ok($last_exception =~ /^warn:/, "_cluck clucked");
}
{
  $last_exception = '';
  eval { POE::Kernel::_carp("testing _carp") };
  ok($last_exception =~ /^warn:/, "_carp carped");
}
{
  $last_exception = '';
  eval { POE::Kernel::_warn("testing _warn") };
  ok($last_exception =~ /^warn:/, "_warn warned");
}
{
  $last_exception = '';
  eval { POE::Kernel::_die("testing _die") };
  ok($last_exception =~ /^die:/, "_die died");
}

exit 0;
