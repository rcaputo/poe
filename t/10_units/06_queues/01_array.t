#!/usr/bin/perl -w

# Tests basic queue operations.

use strict;

use lib qw(./mylib);

use Test::More tests => 2047;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POSIX qw(EPERM ESRCH);

BEGIN { use_ok("POE::Queue::Array") }

my $q = POE::Queue::Array->new();

ok($q->get_item_count == 0, "queue begins empty");
ok(!defined($q->dequeue_next), "can't dequeue from empty queue");

ok($q->enqueue(1, "one") == 1, "first enqueue has id 1");
ok($q->enqueue(3, "tre") == 2, "second enqueue has id 2");
ok($q->enqueue(2, "two") == 3, "third enqueue has id 3");

ok(
  eq_array( [$q->dequeue_next()], [1, 1, "one"] ),
  "event one dequeued correctly"
);

ok(
  eq_array( [$q->dequeue_next()], [2, 3, "two"] ),
  "event two dequeued correctly"
);

ok(
  eq_array( [$q->dequeue_next()], [3, 2, "tre"] ),
  "event three dequeued correctly"
);

ok(
  eq_array( [$q->dequeue_next()], [] ),
  "empty queue marker dequeued correctly"
);

{ my @events = (
    [ a => 1 ],
    [ c => 3 ],
    [ e => 5 ],
    [ b => 2 ],
    [ d => 4 ],
  );

  my $base_event_id = 4;
  enqueue_events(\@events, $base_event_id);
}

# Not constants.
sub always_ok { 1 }
sub never_ok  { 0 }

ok(
  eq_array( [$q->remove_item(7, \&always_ok)], [2, 7, "b"] ),
  "removed event b by its ID"
);

ok(
  eq_array( [$q->remove_item(5, \&always_ok)], [3, 5, "c"] ),
  "removed event c by its ID"
);

ok(
  eq_array( [$q->remove_item(8, \&always_ok)], [4, 8, "d"] ),
  "removed event d by its ID"
);

$! = 0;
ok(
  ( eq_array( [$q->remove_item(6, \&never_ok )], [] ) &&
    $! == EPERM
  ),
  "didn't have permission to remove event e"
);

$! = 0;
ok(
  ( eq_array( [$q->remove_item(8, \&always_ok)], [] ) &&
    $! == ESRCH
  ),
  "couldn't remove nonexistent event d"
);

ok(
  eq_array( [$q->dequeue_next()], [1, 4, "a"] ),
  "dequeued event a correctly"
);

ok(
  eq_array( [$q->dequeue_next()], [5, 6, "e"] ),
  "dequeued event e correctly"
);

ok(
  eq_array( [$q->dequeue_next()], [] ),
  "empty queue marker dequeued correctly"
);

{ my @events = (
    [ a => 1 ],
    [ c => 3 ],
    [ e => 5 ],
    [ b => 2 ],
    [ d => 4 ],
    [ f => 6 ],
  );

  my $base_event_id = 9;
  enqueue_events(\@events, $base_event_id);
}

ok($q->get_item_count() == 6, "queue contains six events");

sub odd_letters  { $_[0] =~ /[ace]/ }
sub even_letters { $_[0] =~ /[bdf]/ }

{ my @items = $q->remove_items(\&odd_letters, 3);
  my @target = (
    [ 1,  9, "a" ],
    [ 3, 10, "c" ],
    [ 5, 11, "e" ],
  );

  ok(eq_array(\@items, \@target), "removed odd letters from queue");
  ok($q->get_item_count() == 3, "leaving three events");
}

{ my @items = $q->remove_items(\&odd_letters, 3);
  my @target;

  ok(eq_array(\@items, \@target), "no more odd letters to remove");
}

{ my @items = $q->remove_items(\&even_letters, 3);
  my @target = (
    [ 2, 12, "b" ],
    [ 4, 13, "d" ],
    [ 6, 14, "f" ],
  );

  ok(eq_array(\@items, \@target), "removed even letters from queue");
  ok($q->get_item_count() == 0, "leaving the queue empty");
}

{ my @events = (
    [ a => 10 ],
    [ b => 20 ],
    [ c => 30 ],
    [ d => 40 ],
    [ e => 50 ],
    [ f => 60 ],
  );

  my $base_event_id = 15;
  enqueue_events(\@events, $base_event_id);
}

ok($q->get_item_count() == 6, "leaving six events in the queue");

{ my @items = $q->peek_items(\&even_letters);
  my @target = (
    [ 20, 16, "b" ],
    [ 40, 18, "d" ],
    [ 60, 20, "f" ],
  );

  ok(eq_array(\@items, \@target), "found even letters in queue");
}

ok(
  $q->adjust_priority(19, \&always_ok, -15) == 35,
  "adjusted event e priority by -15"
);

ok(
  $q->adjust_priority(16, \&always_ok, +15) == 35,
  "adjusted event b priority by +15"
);

{ my @items = $q->remove_items(\&always_ok);
  my @target = (
    [ 10, 15, "a" ],
    [ 30, 17, "c" ],
    [ 35, 19, "e" ], # e got there first
    [ 35, 16, "b" ], # b got there second
    [ 40, 18, "d" ],
    [ 60, 20, "f" ],
  );

  ok(eq_array(\@items, \@target), "colliding priorities are FIFO");
}

ok($q->get_item_count() == 0, "full queue removal leaves zero events");

### Large Queue Tests.  The only functions that use large queues are
### enqueue(), adjust_priority(), and set_priority().  Large queues
### are over ~500 elements.

# Generate a list of events in random priority order.

sub shuffled_list {
  my $limit = shift() - 1;
  my @list = (0..$limit);
  my $i = @list;
  while (--$i) {
    my $j = int rand($i+1);
    @list[$i,$j] = @list[$j,$i];
  }
  @list;
}

sub is_even { !($_[0] % 2) }
sub is_odd  {   $_[0] % 2  }

sub verify_queue {
  my $target_diff = shift;

  my $low_priority = -999999;

  while (my ($pri, $id, $item) = $q->dequeue_next()) {
    my $diff;
    if ($pri < 0) {
      $diff = $item - $pri;
    }
    else {
      $diff = $pri - $item;
    }

    ok(
      ($pri > $low_priority) && ($diff == $target_diff),
      "$item - $pri == $diff (should be $target_diff)"
    );

    $low_priority = $pri;
  }
}

# Enqueue all the events, then adjust their priorities.  The
# even-numbered events have their priorities reduced by 1000; the odd
# ones have their priorities increased by 1000.

{ my @ids;
  for my $major (shuffled_list(10)) {
    for my $minor (shuffled_list(100)) {
      my $priority = sprintf("%2d%02d", $major, $minor);
      push @ids, $q->enqueue($priority, $priority);
    }
  }

  foreach my $id (@ids) { $q->adjust_priority($id, \&is_even, -1000); }
  foreach my $id (@ids) { $q->adjust_priority($id, \&is_odd,   1000); }
}

# Verify that the queue remains in order, and that the adjusted
# priorities are correct.

print "!!!!!!!! 1\n";
verify_queue(1000);

# Now set priorities to absolute values.  The values are

{ my @id_recs;
  for my $major (shuffled_list(10)) {
    for my $minor (shuffled_list(100)) {
      my $priority = sprintf("%2d%02d", $major, $minor);
      push @id_recs, [ $q->enqueue($priority, $priority), $priority ];
    }
  }

  foreach my $id_rec (@id_recs) {
    my ($id, $pri) = @$id_rec;
    $q->set_priority($id, \&is_even, $pri + 500);
  }

  foreach my $id_rec (@id_recs) {
    my ($id, $pri) = @$id_rec;
    $q->set_priority($id, \&is_odd, $pri + 500);
  }

  verify_queue(500);
}

### Helper functions.

sub enqueue_events {
  my ($events, $id) = @_;
  foreach (@$events) {
    my ($ev, $prio) = @$_;
    ok($q->enqueue($prio, $ev) == $id++, "enqueued event $ev correctly");
  }
}
