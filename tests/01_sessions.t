#!/usr/bin/perl -w
# $Id$

# Tests basic compilation and events.

use strict;
use lib qw(./lib ../lib);
use TestSetup qw(13);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;

### Test parameters.

my $machine_count = 10;
my $event_count = 10;

### Status registers for each state machine instance.

my @completions;

### Define a simple state machine.

sub task_start {
  my ($kernel, $heap, $id) = @_[KERNEL, HEAP, ARG0];
  $heap->{count} = 0;
  $kernel->yield( count => $id );
}

sub task_run {
  my ($kernel, $session, $heap, $id) = @_[KERNEL, SESSION, HEAP, ARG0];

  if ( $kernel->call( $session, next_count => $id ) < $event_count ) {

    if ($heap->{count} & 1) {
      $kernel->yield( count => $id );
    }
    else {
      $kernel->post( $session, count => $id );
    }

  }
  else {
    $heap->{id} = $id;
  }
}

sub task_next_count {
  my ($kernel, $session, $heap, $id) = @_[KERNEL, SESSION, HEAP, ARG0];
  ++$heap->{count};
}

sub task_stop {
  $completions[$_[HEAP]->{id}] = $_[HEAP]->{count};
}

### Main loop.

print "ok 1\n";

# Spawn ten state machines.
for (my $i=0; $i<$machine_count; $i++) {

  # Odd instances, try POE::Session->create
  if ($i & 1) {
    POE::Session->create
      ( inline_states =>
        { _start     => \&task_start,
          _stop      => \&task_stop,
          count      => \&task_run,
          next_count => \&task_next_count,
        },
        args => [ $i ],
      );
  }

  # Even instances, try POE::Session->new
  else {
    POE::Session->new
      ( _start     => \&task_start,
        _stop      => \&task_stop,
        count      => \&task_run,
        next_count => \&task_next_count,
        [ $i ],
      );
  }
}

print "ok 2\n";

# Now run them 'til they complete.
$poe_kernel->run();

# Now make sure they've run.
for (my $i=0; $i<$machine_count; $i++) {
  print 'not ' unless $completions[$i] == $event_count;
  print 'ok ', $i+3, "\n";
}

print "ok 13\n";

exit;
