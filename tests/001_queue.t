#!/usr/bin/perl -w
# $Id$

# Tests basic queue operations.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(1061);

use POSIX qw(EPERM ESRCH);

use POE::Queue::Array;

my $q = POE::Queue::Array->new();

ok_if(1, $q->get_item_count == 0);
ok_if(2, !defined($q->dequeue_next));

ok_if(3, $q->enqueue(1, "one") == 1);
ok_if(4, $q->enqueue(3, "tre") == 2);
ok_if(5, $q->enqueue(2, "two") == 3);

sub compare_lists {
  my ($one, $two) = @_;
  return 0 unless @$one == @$two;
  foreach (@$one) {
    return 0 if $_ ne shift @$two;
  }
  return 1;
}

ok_if(6, compare_lists([$q->dequeue_next()], [1, 1, "one"]));
ok_if(8, compare_lists([$q->dequeue_next()], [2, 3, "two"]));
ok_if(7, compare_lists([$q->dequeue_next()], [3, 2, "tre"]));
ok_if(9, compare_lists([$q->dequeue_next()], []));

ok_if(10, $q->enqueue(1, "a") == 4);
ok_if(11, $q->enqueue(3, "c") == 5);
ok_if(12, $q->enqueue(5, "e") == 6);
ok_if(13, $q->enqueue(2, "b") == 7);
ok_if(14, $q->enqueue(4, "d") == 8);

sub always_ok { 1 }
sub never_ok { 0 }

ok_if(15, compare_lists([$q->remove_item(7, \&always_ok)], [2, 7, "b"]));
ok_if(16, compare_lists([$q->remove_item(5, \&always_ok)], [3, 5, "c"]));
ok_if(17, compare_lists([$q->remove_item(8, \&always_ok)], [4, 8, "d"]));

$! = 0;
ok_if(18, compare_lists([$q->remove_item(6, \&never_ok )], []));
ok_if(19, $!==EPERM);

$! = 0;
ok_if(20, compare_lists([$q->remove_item(8, \&always_ok)], []));
ok_if(21, $!==ESRCH);

ok_if(22, compare_lists([$q->dequeue_next()], [1, 4, "a"]));
ok_if(23, compare_lists([$q->dequeue_next()], [5, 6, "e"]));
ok_if(24, compare_lists([$q->dequeue_next()], []));

ok_if(25, $q->enqueue(1, "a") ==  9);
ok_if(26, $q->enqueue(3, "c") == 10);
ok_if(27, $q->enqueue(5, "e") == 11);
ok_if(28, $q->enqueue(2, "b") == 12);
ok_if(29, $q->enqueue(4, "d") == 13);
ok_if(30, $q->enqueue(6, "f") == 14);

ok_if(31, $q->get_item_count() == 6);

sub odd_letters  { $_[0] =~ /[ace]/ }
sub even_letters { $_[0] =~ /[bdf]/ }

my @items;

@items = $q->remove_items(\&odd_letters, 3);
ok_if(32, @items == 3);
ok_if(33, compare_lists($items[0], [1,  9, "a"]));
ok_if(34, compare_lists($items[1], [3, 10, "c"]));
ok_if(35, compare_lists($items[2], [5, 11, "e"]));

ok_if(36, $q->get_item_count() == 3);

@items = $q->remove_items(\&odd_letters, 3);
ok_if(37, @items == 0);

@items = $q->remove_items(\&even_letters, 3);
ok_if(38, @items == 3);
ok_if(39, compare_lists($items[0], [2, 12, "b"]));
ok_if(40, compare_lists($items[1], [4, 13, "d"]));
ok_if(41, compare_lists($items[2], [6, 14, "f"]));

ok_if(42, $q->enqueue(10, "a") == 15);
ok_if(43, $q->enqueue(20, "b") == 16);
ok_if(44, $q->enqueue(30, "c") == 17);
ok_if(45, $q->enqueue(40, "d") == 18);
ok_if(46, $q->enqueue(50, "e") == 19);
ok_if(47, $q->enqueue(60, "f") == 20);

ok_if(48, $q->get_item_count() == 6);

@items = $q->peek_items(\&even_letters);
ok_if(49, $items[0][2] eq "b");
ok_if(50, $items[1][2] eq "d");
ok_if(51, $items[2][2] eq "f");

ok_if(52, $q->adjust_priority(19, \&always_ok, -15) == 35);
ok_if(53, $q->adjust_priority(16, \&always_ok, +15) == 35);

@items = $q->remove_items(\&always_ok);
ok_if(54, @items == 6);

ok_if(55, compare_lists($items[0], [10, 15, "a"]));
ok_if(56, compare_lists($items[1], [30, 17, "c"]));
ok_if(57, compare_lists($items[2], [35, 19, "e"]));
ok_if(58, compare_lists($items[3], [35, 16, "b"]));
ok_if(59, compare_lists($items[4], [40, 18, "d"]));
ok_if(60, compare_lists($items[5], [60, 20, "f"]));

ok_if(61, $q->get_item_count() == 0);

### Large Queue Tests.  The only functions that use large queues are
### enqueue() and adjust_priority().  Large queues are over ~500
### elements.

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

my @ids;
for my $major (shuffled_list(10)) {
  for my $minor (shuffled_list(100)) {
    my $priority = sprintf("%2d%02d", $major, $minor);
    push @ids, $q->enqueue($priority, $priority);
  }
}

sub is_even { !($_[0] % 2) }
sub is_odd  {   $_[0] % 2  }

foreach my $id (@ids) { $q->adjust_priority($id, \&is_even, -1000); }
foreach my $id (@ids) { $q->adjust_priority($id, \&is_odd,   1000); }

my $test_index = 62;
my $low_priority = -999999;

while (my ($pri, $id, $item) = $q->dequeue_next()) {
  if ($pri < 0) {
    ok_if( $test_index++,
           ($pri > $low_priority) && ($pri - $item == -1000)
         );
  }
  else {
    ok_if( $test_index++,
           ($pri > $low_priority) && ($pri - 1000 == $item)
         );
  }
  $low_priority = $pri;
}

results;
