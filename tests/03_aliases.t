#!/usr/bin/perl -w
# $Id$

# Tests basic session aliases.

use strict;
use lib qw(./lib ../lib);
use TestSetup qw(10);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;

### Define a simple state machine.

sub machine_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
  my $resolved_session;

  $heap->{idle_count} = $heap->{zombie_count} = 0;

  # Set an alias.
  $kernel->alias_set( 'new name' );

  # Resolve weak, stringified session reference.
  $resolved_session = $kernel->alias_resolve( "$session" );
  print "not " unless $resolved_session eq $session;
  print "ok 3\n";

  # Resolve against session ID.
  $resolved_session = $kernel->alias_resolve( $session->ID );
  print "not " unless $resolved_session eq $session;
  print "ok 4\n";

  # Resolve against alias.
  $resolved_session = $kernel->alias_resolve( 'new name' );
  print "not " unless $resolved_session eq $session;
  print "ok 5\n";

  # Resolve against blessed session reference.
  $resolved_session = $kernel->alias_resolve( $session );
  print "not " unless $resolved_session eq $session;
  print "ok 6\n";

  # Resolve against something that doesn't exist.
  $resolved_session = $kernel->alias_resolve( 'nonexistent' );
  print "not " if defined $resolved_session;
  print "ok 7\n";
}

# Catch SIGIDLE and SIGZOMBIE.

sub machine_signal {
  my ($kernel, $heap, $signal) = @_[KERNEL, HEAP, ARG0];

  if ($signal eq 'IDLE') {
    $heap->{idle_count}++;
    return 1;
  }

  if ($signal eq 'ZOMBIE') {
    $heap->{zombie_count}++;
    return 1;
  }

  # Don't handle other signals.
  return 0;
}

# Make sure we got one SIGIDLE and one SIGZOMBIE.

sub machine_stop {
  my $heap = $_[HEAP];

  print "not " unless $heap->{idle_count} == 1;
  print "ok 8\n";

  print "not " unless $heap->{zombie_count} == 1;
  print "ok 9\n";
}

### Main loop.

print "ok 1\n";

# Spawn a state machine for testing.

POE::Session->create
  ( inline_states =>
    { _start => \&machine_start,
      _signal => \&machine_signal,
      _stop => \&machine_stop
    },
  );

print "ok 2\n";

# Now run the kernel until there's nothing left to do.

$poe_kernel->run();

print "ok 10\n";

exit;
