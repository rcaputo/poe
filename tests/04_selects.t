#!/usr/bin/perl -w
# $Id$

# Tests basic select operations.

use strict;
use lib qw(./lib ../lib);
use TestSetup qw(99);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;
use Socket;
use Symbol qw(gensym);

### Test parameters.

my $pair_count = 10;
my $chat_count = 100;

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

  # Create a socket pain.
  my ($master_socket, $slave_socket) = (gensym, gensym);
  my $proto = getprotobyname('tcp');
  die "could not get tcp protocol number: $!" unless defined $proto;
  socketpair($master_socket, $slave_socket, AF_INET, SOCK_STREAM, $proto)
    or die "could not open a socket pain: $!";

  # Select on one side.
  select_read($master_socket, 'input');

  # Give the other side to a newly spawned session.
  POE::Session->create
    ( inline_states =>
      { _start => \&slave_start,
        _stop  => \&slave_stop,
        input  => \&slave_input,
      },
      args     => [ $slave_socket, $test_index + 1 ],
    );

  # Save some values for later.
  $heap->{socket} = $master_socket;
  $heap->{test_index} = $test_index;
  $heap->{test_count} = 0;
}

sub master_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Determine if we were successful.
  $test_results[$heap->{test_index}] = ($heap->{test_count} == $chat_count);
}

sub master_got_input {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];

  my $buffer = '';
  my $got = recv($handle, $buffer, 4, 0);

  # The other session requested a quit.  Shut down gracefully.
  if ($buffer eq 'quit') {
    select_read($handle);
    return;
  }

  # The other session sent a ping.  Count it, and send a pong.
  if ($buffer eq 'ping') {
    $heap->{test_count}++;
    my $sent = send($handle, 'pong', 0);

    # Stop on error.
    select_read($handle) unless $sent == 4;
    return;
  }
}

### Slave session.

sub slave_start {
  my ($kernel, $heap, $handle, $test_index) = @_[KERNEL, HEAP, ARG0, ARG1];

  # Select on our socket.
  select_read($handle, 'input');

  # Say hello to the master session.
  send($handle, 'ping', 0);
}

sub slave_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Determine if we were successful.
  $test_results[$heap->{test_index}] = ($heap->{test_count} == $chat_count);
}

sub slave_got_input {
  my ($kernel, $heap, $handle) = @_[KERNEL, HEAP, ARG0];

  my $buffer = '';
  my $got = recv($handle, $buffer, 4, 0);

  # The other session requested a quit.  Shut down gracefully.
  if ($buffer eq 'quit') {
    select_read($handle);
    return;
  }

  # The other session sent a pong.
  if ($buffer eq 'pong') {

    # Count it.
    $heap->{test_count}++;

    # Send another ping if we're not done.
    if ($heap->{test_count} < $chat_count) {
      my $sent = send($handle, 'ping', 0);

      # Stop on error.
      select_read($handle) unless $sent == 4;
    }

    # Otherwise we're done.  Send a quit, and quit ourselves.
    else {
      my $sent = send($handle, 'quit', 0);

      # Stop on error.
      select_read($handle) unless $sent == 4;
    }

  }

  # Received a message from the master session.
  # Make a note.
  # Send a response to the master.

}

### Main loop.

print "ok 1\n";

# Spawn a group of master sessions.

for (my $index = 0; $index < $pair_count; $index++) {
  POE::Session->create
    ( inline_states =>
      { _start => \&master_start,
        _stop  => \&master_stop,
        input  => \&master_got_input,
      },
      args     => [ $index ],
    );
}

print "ok 2\n";

# Now run them until they're done.
$poe_kernel->run();

# Now make sure they've run.
for (my $index = 0; $index < $pair_count << 1; $index++) {
  "not " unless $test_results[$index];
  print "ok ", $index + 3, "\n";
}

# And one to grow on.
print "ok 99\n";

exit;
