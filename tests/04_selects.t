#!/usr/bin/perl -w
# $Id$

# Tests basic select operations.

use strict;
use lib qw(./lib ../lib);
use TestSetup;

&test_setup(13);

# Turn on all asserts.
#sub POE::Kernel::TRACE_EVENTS () { 1 }
#sub POE::Kernel::TRACE_SELECT () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw(Pipe::TwoWay);

### Test parameters.

my $pair_count = 5;
my $chat_count = 5;

### Register for individual test results.

my @test_results;

# What to do here?  Create ten master sessions that create socket
# pairs.  Each master session spawns a slave session and gives it the
# other end of the pair.  The master and slave chat a while, then the
# slave exits (odd pairs) or the master exits (even pairs).
# Everything should shut down cleanly.

# We'll use send and recv with small enough packets to avoid worrying
# about combining broken datagrams.

### Master session.

sub master_start {
  my ($kernel, $heap, $test_index) = @_[KERNEL, HEAP, ARG0];

  $test_index *= 2;

  my ($master_read, $master_write, $slave_read, $slave_write) =
    POE::Pipe::TwoWay->new();

  unless (defined $master_read) {
    $test_results[$test_index] = $test_results[$test_index + 1] = undef;
    return;
  }

  # Listen on the uplink_read side.
  $kernel->select_read($master_read, 'input');

  # Give the other side to a newly spawned session.
  POE::Session->create
    ( inline_states =>
      { _start => \&slave_start,
        _stop  => \&slave_stop,
        input  => \&slave_got_input,
        resume => \&slave_resume_read,
        output => \&slave_put_output,
      },
      args     => [ $slave_read, $slave_write, $test_index + 1 ],
    );

  # Save some values for later.
  $heap->{write}      = $master_write;
  $heap->{test_index} = $test_index;
  $heap->{test_count} = 0;
  $heap->{queue}      = [ ];

  # Start the write thing.
  $kernel->select_write($master_write, 'output');
}

sub master_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Determine if we were successful.
  $test_results[$heap->{test_index}] = ($heap->{test_count} == $chat_count);
}

sub master_got_input {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];

  my $received = sysread($handle, my $buffer = '', 4);
  unless ($received == 4) {
    $kernel->select_read($handle);
    $kernel->select_write($heap->{write});
    return;
  }

  # The other session requested a quit.  Shut down gracefully.
  if ($buffer eq 'quit') {
    $kernel->select_read($handle);
    $kernel->select_write($heap->{write});
    return;
  }

  # The other session sent a ping.  Count it, and send a pong.
  if ($buffer eq 'ping') {
    $heap->{test_count}++;
    push @{$heap->{queue}}, 'pong';
    $kernel->select_resume_write($heap->{write});
  }
}

sub master_put_output {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];

  # If there is a message queued, write it.
  if (@{$heap->{queue}}) {
    my $message = shift @{$heap->{queue}};
    die $!
      unless syswrite($handle, $message, length($message)) == length($message);
  }

  # Otherwise pause the write select.
  else {
    $kernel->select_pause_write($handle);
  }
}

### Slave session.

sub slave_start {
  my ($kernel, $heap, $read_handle, $write_handle, $test_index) =
    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

  # Select on our read handle.
  $kernel->select_read($read_handle, 'input');

  # Remember some things.
  $heap->{read}       = $read_handle;
  $heap->{write}      = $write_handle;
  $heap->{test_index} = $test_index;
  $heap->{queue}      = [ ];

  # Say hello to the master session.
  push @{$heap->{queue}}, 'ping';
  $kernel->select_write($write_handle, 'output');
}

sub slave_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Determine if we were successful.
  $test_results[$heap->{test_index}] = ($heap->{test_count} == $chat_count);
}

# Resume reading after a brief delay.
sub slave_resume_read {
  $_[KERNEL]->select_resume_read( $_[HEAP]->{read} );
  $_[KERNEL]->delay( error_resuming => undef );
  $_[HEAP]->{resume_count}++;
}

sub slave_got_input {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];

  my $received = sysread($handle, my $buffer = '', 4);
  unless ($received == 4) {
    $kernel->select_read($handle);
    $kernel->select_write($heap->{write});
    return;
  }

  # The other session sent a pong.
  if ($buffer eq 'pong') {
    $heap->{test_count}++;

    # Send another ping if we're not done.
    if ($heap->{test_count} < $chat_count) {
      push @{$heap->{queue}}, 'ping';
      $kernel->select_resume_write($heap->{write});

      # Pause reading.  Gets resumed after a delay.
      $kernel->select_pause_read( $heap->{read} );
      $kernel->delay( resume => 0.5 );
    }

    # Otherwise we're done.  Send a quit, and quit ourselves.
    else {
      push @{$heap->{queue}}, 'quit';
      $kernel->select_read($handle);
      $kernel->select_resume_write($heap->{write});
    }
  }
}

sub slave_put_output {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];

  # If there is a message queued, write it.
  if (@{$heap->{queue}}) {
    my $message = shift @{$heap->{queue}};
    die $!
      unless syswrite($handle, $message, length($message)) == length($message);

    # Kludge.  We requested quit, so go ahead and quit.
    $kernel->select_write($handle) if $message eq 'quit';
  }

  # Otherwise pause the write select.
  else {
    $kernel->select_pause_write($handle);
  }
}

### Main loop.

print "ok 1\n";

# Spawn a group of master sessions.

for (my $index = 0; $index < $pair_count; $index++) {
  POE::Session->create
    ( inline_states =>
      { _start => \&master_start,
        _stop  => \&master_stop,
        _child => sub { },
        input  => \&master_got_input,
        output => \&master_put_output,
      },
      args     => [ $index ],
    );
}

print "ok 2\n";

# Now run them until they're done.
$poe_kernel->run();

# Now make sure they've run.
for (my $index = 0; $index < $pair_count << 1; $index++) {
  print "not " unless $test_results[$index];
  print "ok ", $index + 3, "\n";
}

# And one to grow on.
print "ok 13\n";

exit;
