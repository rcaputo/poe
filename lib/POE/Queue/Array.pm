# $Id$
# Copyrights and documentation are at the end.

package POE::Queue::Array;

use strict;

use vars qw(@ISA);
@ISA = qw(POE::Queue);

use POSIX qw(ESRCH EPERM);

### Helpful offsets.

sub ITEM_PRIORITY () { 0 }
sub ITEM_ID       () { 1 }
sub ITEM_PAYLOAD  () { 2 }

sub import {
  my $package = caller();
  no strict 'refs';
  *{ $package . '::ITEM_PRIORITY' } = \&ITEM_PRIORITY;
  *{ $package . '::ITEM_ID'       } = \&ITEM_ID;
  *{ $package . '::ITEM_PAYLOAD'  } = \&ITEM_PAYLOAD;
}

# Item IDs are unique across all queues.

my $queue_seq = 0;
my %item_priority;

# Theoretically, linear array search performance begins to suffer
# after a queue grows large enough.  This is the largest queue size
# before searches are performed as binary lookups.

sub LARGE_QUEUE_SIZE () { 512 }

### A very simple constructor.

sub new {
  bless [];
}

### Add an item to the queue.  Returns the new item's ID.

sub enqueue {
  my ($self, $priority, $payload) = @_;

  # Get the next item ID.  This clever loop will hang indefinitely if
  # you ever run out of integers to store things under.  Map the ID to
  # its due time for search-by-ID functions.

  my $item_id;
  1 while exists $item_priority{$item_id = ++$queue_seq};
  $item_priority{$item_id} = $priority;

  my $item_to_enqueue =
    [ $priority, # ITEM_PRIORITY
      $item_id,  # ITEM_ID
      $payload,  # ITEM_PAYLOAD
    ];

  # Special case: No items in the queue.  The queue IS the item.
  unless (@$self) {
    $self->[0] = $item_to_enqueue;
    return $item_id;
  }

  # Special case: The new item belongs at the end of the queue.
  if ($priority >= $self->[-1]->[ITEM_PRIORITY]) {
    push @$self, $item_to_enqueue;
    return $item_id;
  }

  # Special case: The new item belongs at the head of the queue.
  if ($priority < $self->[0]->[ITEM_PRIORITY]) {
    unshift @$self, $item_to_enqueue;
    return $item_id;
  }

  # Special case: There are only two items in the queue.  This item
  # naturally belongs between them.
  if (@$self == 2) {
    splice @$self, 1, 0, $item_to_enqueue;
    return $item_id;
  }

  # A small queue is scanned linearly on the assumptions that (a) the
  # linear search has less overhead than a binary search for small
  # queues, and (b) most items will be posted for "now" or some future
  # time, which tends to place them at the end of the queue.

  if (@$self < LARGE_QUEUE_SIZE) {
    my $index = @$self;
    $index--
      while ( $index and
              $priority < $self->[$index-1]->[ITEM_PRIORITY]
            );
    splice @$self, $index, 0, $item_to_enqueue;
    return $item_id;
  }

  # And finally, we have this large queue, and the program has already
  # wasted enough time.  Insert the item using a binary seek.

  $self->_insert_item(0, $#$self, $priority, $item_to_enqueue);
  return $item_id;
}

### Dequeue the next thing from the queue.  Returns an empty list if
### the queue is empty.  There are different flavors of this
### operation.

sub dequeue_next {
  my $self = shift;

  return unless @$self;
  my ($priority, $id, $stuff) = @{shift @$self};
  delete $item_priority{$id};
  return ($priority, $id, $stuff);
}

### Return the next item's priority, undef if the queue is empty.

sub get_next_priority {
  my $self = shift;
  return undef unless @$self;
  return $self->[0]->[ITEM_PRIORITY];
}

### Return the number of items currently in the queue.

sub get_item_count {
  my $self = shift;
  return scalar @$self;
}

### Internal method to insert an item in a large queue.  Performs a
### binary seek between two bounds to find the insertion point.  We
### accept the bounds as parameters because the alarm adjustment
### functions may also use it.

sub _insert_item {
  my ($self, $lower, $upper, $priority, $item) = @_;

  while (1) {
    my $midpoint = ($upper + $lower) >> 1;

    # Upper and lower bounds crossed.  No match; insert at the lower
    # bound point.
    if ($upper < $lower) {
      splice @$self, $lower, 0, $item;
      return;
    }

    # The key at the midpoint is too high.  The item just below the
    # midpoint becomes the new upper bound.
    if ($priority < $self->[$midpoint]->[ITEM_PRIORITY]) {
      $upper = $midpoint - 1;
      next;
    }

    # The key at the midpoint is too low.  The item just above the
    # midpoint becomes the new lower bound.
    if ($priority > $self->[$midpoint]->[ITEM_PRIORITY]) {
      $lower = $midpoint + 1;
      next;
    }

    # The key matches the one at the midpoint.  Scan towards higher
    # keys until the midpoint points to an item with a higher key.
    # Insert the new item before it.
    $midpoint++
      while ( ($midpoint < @$self)
              and ( $priority ==
                    $self->[$midpoint]->[ITEM_PRIORITY]
                  )
            );
    splice @$self, $midpoint, 0, $item;
    return;
  }

  # We should never reach this point.
  die;
}

### Internal method to find a queue item by its priority and ID.  We
### assume the priority and ID have been verified already, so the item
### must exist.  Returns the index of the item that matches the
### priority/ID pair.

sub _find_item {
  my ($self, $id, $priority) = @_;

  # Small queue.  Assume a linear search is faster.
  if (@$self < LARGE_QUEUE_SIZE) {
    my $index = @$self;
    while ($index--) {
      return $index if $id == $self->[$index]->[ITEM_ID];
    }
    die "internal inconsistency: event should have been found";
  }

  # Use a binary seek on larger queues.

  my $upper = $#$self; # Last index of @$self.
  my $lower = 0;
  while (1) {
    my $midpoint = ($upper + $lower) >> 1;

    # The streams have crossed.  That's bad.
    die "internal inconsistency: event should have been found"
      if $upper < $lower;

    # The key at the midpoint is too high.  The element just below
    # the midpoint becomes the new upper bound.
    if ($priority < $self->[$midpoint]->[ITEM_PRIORITY]) {
      $upper = $midpoint - 1;
      next;
    }

    # The key at the midpoint is too low.  The element just above
    # the midpoint becomes the new lower bound.
    if ($priority > $self->[$midpoint]->[ITEM_PRIORITY]) {
      $lower = $midpoint + 1;
      next;
    }

    # The key (priority) matches the one at the midpoint.  This may be
    # in the middle of a pocket of events with the same priority, so
    # we'll have to search back and forth for one with the ID we're
    # looking for.  Unfortunately.
    my $linear_point = $midpoint;
    while ( $linear_point >= 0 and
            $priority == $self->[$linear_point]->[ITEM_PRIORITY]
          ) {
      return $linear_point if $self->[$linear_point]->[ITEM_ID] == $id;
      $linear_point--;
    }
    $linear_point = $midpoint;
    while ( (++$linear_point < @$self) and
            ($priority == $self->[$linear_point]->[ITEM_PRIORITY])
          ) {
      return $linear_point if $self->[$linear_point]->[ITEM_ID] == $id;
    }

    # If we get this far, then the event hasn't been found.
    die "internal inconsistency: event should have been found";
  }
}

### Remove an item by its ID.  Takes a coderef filter, too, for
### examining the payload to be sure it really wants to leave.  Sets
### $! and returns undef on failure.

sub remove_item {
  my ($self, $id, $filter) = @_;

  my $priority = $item_priority{$id};
  unless (defined $priority) {
    $! = ESRCH;
    return;
  }

  # Find that darn item.
  my $item_index = $self->_find_item($id, $priority);

  # Test the item against the filter.
  unless ($filter->($self->[$item_index]->[ITEM_PAYLOAD])) {
    $! = EPERM;
    return;
  }

  # Remove the item, and return it.
  delete $item_priority{$id};
  return @{splice @$self, $item_index, 1};
}

### Remove items matching a filter.  Regrettably, this must scan the
### entire queue.  An optional count limits the number of items to
### remove, and it may shorten execution times.  Returns a list of
### references to priority/id/payload lists.  This is intended to
### return all the items matching the filter, and the function's
### behavior is undefined when $count is less than the number of
### matching items.

sub remove_items {
  my ($self, $filter, $count) = @_;
  $count = @$self unless $count;

  my @items;
  my $i = @$self;
  while ($i--) {
    if ($filter->($self->[$i]->[ITEM_PAYLOAD])) {
      my $removed_item = splice(@$self, $i, 1);
      delete $item_priority{$removed_item->[ITEM_ID]};
      unshift @items, $removed_item;
      last unless --$count;
    }
  }

  return @items;
}

### Adjust the priority of an item by a relative amount.  Adds $delta
### to the priority of the $id'd object (if it matches $filter), and
### moves it in the queue.  This tries to be clever by not scanning
### the queue more than necessary.

sub adjust_priority {
  my ($self, $id, $filter, $delta) = @_;

  my $priority = $item_priority{$id};
  unless (defined $priority) {
    $! = ESRCH;
    return;
  }

  # Find that darn item.
  my $item_index = $self->_find_item($id, $priority);

  # Test the item against the filter.
  unless ($filter->($self->[$item_index]->[ITEM_PAYLOAD])) {
    $! = EPERM;
    return;
  }

  # Nothing to do if the delta is zero.
  return $self->[$item_index]->[ITEM_PRIORITY] unless $delta;

  # Remove the item, and adjust its priority.
  my $item = splice(@$self, $item_index, 1);
  my $new_priority = $item->[ITEM_PRIORITY] += $delta;
  $item_priority{$id} = $new_priority;

  # Now insert it back.  The special cases are duplicates from
  # enqueue(), but the small and large queue cases avoid unnecessarily
  # scanning the queue.

  # Special case: No events in the queue.  The queue IS the item.
  unless (@$self) {
    $self->[0] = $item;
    return $new_priority;
  }

  # Special case: The item belongs at the end of the queue.
  if ($new_priority >= $self->[-1]->[ITEM_PRIORITY]) {
    push @$self, $item;
    return $new_priority;
  }

  # Special case: The item blenogs at the head of the queue.
  if ($new_priority < $self->[0]->[ITEM_PRIORITY]) {
    unshift @$self, $item;
    return $new_priority;
  }

  # Special case: There are only two items in the queue.  This item
  # naturally belongs between them.

  if (@$self == 2) {
    splice @$self, 1, 0, $item;
    return $new_priority;
  }

  # Small queue.  Perform a reverse linear search (see enqueue() for
  # assumptions).  We don't consider the entire queue size; only the
  # number of items between the $item_index and the end of the queue
  # pointed at by $delta.

  # The item has been moved towards the queue's tail, which is nearby.
  if ($delta > 0 and (@$self - $item_index) < LARGE_QUEUE_SIZE) {
    my $index = $item_index;
    $index++
      while ( $index < @$self and
              $new_priority >= $self->[$index]->[ITEM_PRIORITY]
            );
    splice @$self, $index, 0, $item;
    return $new_priority;
  }

  # The item has been moved towards the queue's head, which is nearby.
  if ($delta < 0 and $item_index < LARGE_QUEUE_SIZE) {
    my $index = $item_index;
    $index--
      while ( $index and
              $new_priority < $self->[$index-1]->[ITEM_PRIORITY]
            );
    splice @$self, $index, 0, $item;
    return $new_priority;
  }

  # The item has moved towards an end of the queue, but there are a
  # lot of items into which it may be inserted.  We'll binary seek.

  my ($upper, $lower);
  if ($delta > 0) {
    $upper = $#$self; # Last index in @$self.
    $lower = $item_index;
  }
  else {
    $upper = $item_index;
    $lower = 0;
  }

  $self->_insert_item($lower, $upper, $new_priority, $item);
  return $new_priority;
}

### Peek at items that match a filter.  Returns a list of payloads
### that match the supplied coderef.

sub peek_items {
  my ($self, $filter, $count) = @_;
  $count = @$self unless $count;

  my @items;
  my $i = @$self;
  while ($i--) {
    if ($filter->($self->[$i]->[ITEM_PAYLOAD])) {
      unshift @items, $self->[$i];
      last unless --$count;
    }
  }

  return @items;
}

1;

__END__

=head1 NAME

POE::Queue::Array - an array based high-performance priority queue for POE

=head1 SYNOPSIS

  $queue = POE::Queue::Array->new();

  $payload_id = $queue->enqueue($priority, $payload);

  ($priority, $id, $payload) = $queue->dequeue_next();

  $next_priority = $queue->get_next_priority();
  $item_count = $queue->get_item_count();

  ($priority, $id, $payload) = $q->remove_item($id, \&filter);

  @items = $q->remove_items(\&filter, $count);  # $count is optional

  @items = $q->peek_items(\&filter, $count);  # $count is optional

  $new_priority = $q->adjust_priority($id, \&filter, $delta);

=head1 DESCRIPTION

Priority queues may be implemented as ordered lists, where lists are
ordered by a "priority".  The only restruction on priorities is that
they be numbers.  In POE, for example, the "priority" is the UNIX
epoch time that an item should be dequeued.

All POE::Queue classes order priorities from lowest to highest value.
Items with the same priority are entered into the queue in FIFO order.
That is, items at the same priority are dequeued in the order they
achieved a that priority.

=over 4

=item $queue = POE::Queue::Array->new();

Creates a priority queue, returning its reference.

=item $payload_id = $queue->enqueue($priority, $payload);

Enqueue a payload, which can be just about anything, at a specified
priority level.  Returns a unique ID which can be used to manipulate
the payload or its priority directly.

The payload will be placed into the queue in priority order, from
lowest to highest.  The new payload will follow any others that
already exist in the queue at the specified priority.

=item ($priority, $id, $payload) = $queue->dequeue_next();

Returns the priority, ID, and payload of the item with the lowest
priority.  If several items exist with the same priority, it returns
the one that was at that priority the longest.

=item $next_priority = $queue->get_next_priority();

Returns the priority of the item at the head of the queue.  This is
the lowest priority in the queue.

=item $item_count = $queue->get_item_count();

Returns the number of items in the queue.

=item ($priority, $id, $payload) = $q->remove_item($id, \&filter);

Removes an item by its ID, but only if its payload passes the tests in
a filter function.  If a payload is found with the given ID, it is
passed by reference to the filter function.  This filter only allows
wombats to be removed from a queue.

  sub filter {
    my $payload = $_[0];
    return 1 if $payload eq "wombat";
    return 0;
  }

Returns undef on failure, and sets $! to the reason why the call
failed: ESRCH if the $id did not exist in the queue, or EPERM if the
filter function returned 0.

=item @items = $q->remove_items(\&filter);

=item @items = $q->remove_items(\&filter, $count);

Removes multiple items that match a filter function from a queue.
Returns them as a list of list references.  Each returned item is

  [ $priority, $id, $payload ].

This filter does not allow anything to be removed.

  sub filter { 0 }

The $count is optional.  If supplied, remove_items() will remove at
most $count items.  This is useful when you know how many items exist
in the queue to begin with, as POE sometimes does.  If a $count is
supplied, it should be correct.  There is no telling which items are
removed by remove_items() if $count is too low.

=item @items = $q->peek_items(\&filter);

=item @items = $q->peek_items(\&filter, $count);

Returns a list of items that match a filter function from a queue.
The items are not removed from the list.  Each returned item is a list
reference

  [ $priority, $id, $payload ]

This filter only lets you move monkeys.

  sub filter {
    return $_[0]->[TYPE] & IS_A_MONKEY;
  }

The $count is optional.  If supplied, peek_items() will return at most
$count items.  This is useful when you know how many items exist in
the queue to begin with, as POE sometimes does.  If a $count is
supplied, it should be correct.  There is no telling which items are
returned by peek_items() if $count is too low.

=item $new_priority = $q->adjust_priority($id, \&filter, $delta);

Changes the priority of an item by +$delta (which can be negative).
The item is identified by its $id, but the change will only happen if
the supplied filter function returns true.  Returns $new_priority,
which is the priority of the item after it has been adjusted.

This filter function allows anything to be removed.

  sub filter { 1 }

=back

=head1 SEE ALSO

POE, ADT::PriorityQueue

=head1 BUGS

POE::Queue is not documented.  It should discuss the POE::Queue
interface so that implementations do not need to duplicate the
background.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
