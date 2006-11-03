#!/usr/bin/perl -w
# $Id$

# Tests basic session aliases.

use strict;

use Test::More tests => 20;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POSIX qw (:errno_h);

BEGIN { use_ok("POE"); }

### Define a simple state machine.

sub machine_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
  my $resolved_session;

  $kernel->sig(IDLE => "sigidle");
  $kernel->sig(ZOMBIE => "sigzombie");

  $heap->{idle_count} = $heap->{zombie_count} = 0;

  ok(!$kernel->alias_set('new name'), "setting new alias");
  ok(!$kernel->alias_set('new name'), "overwriting new alias");

  $resolved_session = $kernel->alias_resolve( "$session" );
  ok($resolved_session eq $session, "resolve stringified session reference");

  $resolved_session = $kernel->alias_resolve( $session->ID );
  ok($resolved_session eq $session, "resolve session ID");

  $resolved_session = $kernel->alias_resolve( 'new name' );
  ok($resolved_session eq $session, "resolve alias");

  $resolved_session = $kernel->alias_resolve( $session );
  ok($resolved_session eq $session, "resolve session reference");

  $resolved_session = eval { $kernel->alias_resolve( 'nonexistent' ) };
  ok(!$resolved_session, "fail to resolve nonexistent alias");

  my $id = $session->ID;
  ok($kernel->ID_id_to_session($id) == $session, "id resolves to session");
  ok($kernel->ID_session_to_id($session) == $id, "session resolves to id");

  ok(
    $kernel->ID_id_to_session($kernel->ID) == $kernel,
    "kernel id resolves to kernel reference"
  );

  ok(
    $kernel->ID_session_to_id($kernel) eq $kernel->ID,
    "kernel reference resolves to kernel id"
  );

  # Check alias list for session.
  my @aliases = $kernel->alias_list();
  ok(@aliases == 1, "session has only one alias");
  ok($aliases[0] eq 'new name', "session's alias is 'new name'");

  # Set and test a second alias.
  $kernel->alias_set( 'second name' );
  @aliases = sort $kernel->alias_list( $session );
  ok(@aliases == 2, "session now has two aliases");
  ok($aliases[0] eq 'new name', "session has 'new name' alias");
  ok($aliases[1] eq 'second name', "session has 'second name' alias");
}

# Catch SIGIDLE and SIGZOMBIE and count them.

sub machine_sig_idle {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{idle_count}++;
  return $kernel->sig_handled();
}

sub machine_sig_zombie {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{zombie_count}++;
  return $kernel->sig_handled();
}

# Make sure we got one SIGIDLE and one SIGZOMBIE.

sub machine_stop {
  my $heap = $_[HEAP];
  ok($heap->{idle_count} == 1, "session received one SIGIDLE");
  ok($heap->{zombie_count} == 1, "session received one SIGZOMBIE");
}

# Spawn a state machine for testing.

POE::Session->create(
  inline_states => {
    _start    => \&machine_start,
    sigidle   => \&machine_sig_idle,
    sigzombie => \&machine_sig_zombie,
    _stop     => \&machine_stop
  },
);

my $sigidle_test = 1;
my $sigzombie_test = 1;

POE::Session->create(
  inline_states => {
    _start => sub {
      my $kernel = $_[KERNEL];
      $kernel->alias_set( 'a_sample_alias' );

      ok(!$_[KERNEL]->alias_remove('a_sample_alias'), "removing simple alias");

      $kernel->sig(IDLE   => "sigidle");
      $kernel->sig(ZOMBIE => "sigzombie");
    },
    sigidle   => sub { $sigidle_test = 0;   },
    sigzombie => sub { $sigzombie_test = 0; },
    _stop => sub { },
  }
);

# Now run the kernel until there's nothing left to do.

POE::Kernel->run();

1;
