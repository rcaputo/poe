#!/usr/bin/perl -w
# $Id$

# Tests alarms.

use strict;
use lib qw(./lib ../lib);
use TestSetup;

&test_setup(14);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

### Test parameters.

my $machine_count = 10;
my $event_count = 10;

### Status registers for each state machine instance.

my @status;


### Define a simple state machine.

sub test_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Path #1: single alarm; make sure it rings.
  $heap->{test}->{path_one} = 0;
  $kernel->alarm( path_one => time() + 2, 1.1 );

  # Path #2: two alarms; make sure only the second one rings.
  $heap->{test}->{path_two} = 0;
  $kernel->alarm( path_two => time() + 2, 2.1 );
  $kernel->alarm( path_two => time() + 2, 2.2 );

  # Path #3: two alarms; make sure they both ring in order.
  $heap->{test}->{path_three} = 0;
  $kernel->alarm_add( path_three => time() + 2, 3.1 );
  $kernel->alarm_add( path_three => time() + 2, 3.2 );

  # Path #4: interleaved alarm and alarm_add; only the last two should
  # ring, in order.
  $heap->{test}->{path_four} = 0;
  $kernel->alarm(     path_four => time() + 2, 4.1 );
  $kernel->alarm_add( path_four => time() + 2, 4.2 );
  $kernel->alarm(     path_four => time() + 2, 4.3 );
  $kernel->alarm_add( path_four => time() + 2, 4.4 );

  # Path #5: an alarm that is squelched; nothing should ring.
  $heap->{test}->{path_five} = 1;
  $kernel->alarm( path_five => time() + 2, 5.1 );
  $kernel->alarm( 'path_five' );

  # Path #6: single delay; make sure it rings.
  $heap->{test}->{path_six} = 0;
  $kernel->delay( path_six => 2, 6.1 );

  # Path #7: two delays; make sure only the second one rings.
  $heap->{test}->{path_seven} = 0;
  $kernel->delay( path_seven => 2, 7.1 );
  $kernel->delay( path_seven => 2, 7.2 );

  # Path #8: two delays; make sure they both ring in order.
  $heap->{test}->{path_eight} = 0;
  $kernel->delay_add( path_eight => 2, 8.1 );
  $kernel->delay_add( path_eight => 2, 8.2 );

  # Path #9: interleaved delay and delay_add; only the last two should
  # ring, in order.
  $heap->{test}->{path_nine} = 0;
  $kernel->alarm(     path_nine => 2, 9.1 );
  $kernel->alarm_add( path_nine => 2, 9.2 );
  $kernel->alarm(     path_nine => 2, 9.3 );
  $kernel->alarm_add( path_nine => 2, 9.4 );

  # Path #10: a delay that is squelched; nothing should ring.
  $heap->{test}->{path_ten} = 1;
  $kernel->delay( path_ten => 2, 10.1 );
  $kernel->alarm( 'path_ten' );

  # Path #11: ensure alarms are enqueued in time order.

  # Fill the alarm queue to engage the "big queue" binary insert.
  my @eleven_fill;
  for (my $count=0; $count<100; $count++) {
    push @eleven_fill, int(rand(100));
    $kernel->alarm( "path_eleven_fill_$count", $eleven_fill[-1] );
  }

  # Now to really test the insertion code.
  $kernel->alarm( path_eleven_100 => 100 );
  $kernel->alarm( path_eleven_200 => 200 );
  $kernel->alarm( path_eleven_300 => 300 );

  $kernel->alarm( path_eleven_050 =>  50 );
  $kernel->alarm( path_eleven_150 => 150 );
  $kernel->alarm( path_eleven_250 => 250 );
  $kernel->alarm( path_eleven_350 => 350 );

  $kernel->alarm( path_eleven_075 =>  75 );
  $kernel->alarm( path_eleven_175 => 175 );
  $kernel->alarm( path_eleven_275 => 275 );

  $kernel->alarm( path_eleven_325 => 325 );
  $kernel->alarm( path_eleven_225 => 225 );
  $kernel->alarm( path_eleven_125 => 125 );

  # To test duplicates.
  $kernel->alarm( path_eleven_201 => 200 );
  $kernel->alarm( path_eleven_202 => 200 );
  $kernel->alarm( path_eleven_203 => 200 );

  # Now clear the filler states.
  for (my $count=0; $count<100; $count++) {
    if ($count & 1) {
      $kernel->alarm( "path_eleven_fill_$count" );
    }
    else {
      $kernel->alarm( "path_eleven_fill_$count" );
    }
  }

  # Now acquire the test alarms.
  my @alarms_eleven = grep /^path_eleven_\d+$/, $kernel->queue_peek_alarms();
  $heap->{alarms_eleven} = \@alarms_eleven;

  # Now clear the test alarms since we're just testing the queue
  # order.
  foreach (@alarms_eleven) {
    $kernel->alarm( $_ );
  }

  # All the paths are occurring in parallel so they should complete in
  # about 2 seconds.  Start a timer to make sure.
  $heap->{start_time} = time();
}

sub test_stop {
  my $heap = $_[HEAP];

  print 'not ' unless $heap->{test}->{path_one} == 1;
  print "ok 2\n";

  print 'not ' unless $heap->{test}->{path_two} == 1;
  print "ok 3\n";

  print 'not ' unless $heap->{test}->{path_three} == 11;
  print "ok 4\n";

  print 'not ' unless $heap->{test}->{path_four} == 11;
  print "ok 5\n";

  print 'not ' unless $heap->{test}->{path_five} == 1;
  print "ok 6\n";

  print 'not ' unless $heap->{test}->{path_six} == 1;
  print "ok 7\n";

  print 'not ' unless $heap->{test}->{path_seven} == 1;
  print "ok 8\n";

  print 'not ' unless $heap->{test}->{path_eight} == 11;
  print "ok 9\n";

  print 'not ' unless $heap->{test}->{path_nine} == 11;
  print "ok 10\n";

  print 'not ' unless $heap->{test}->{path_ten} == 1;
  print "ok 11\n";

  # Here's where we check the overall run time.
  print 'not ' if (time() - $heap->{start_time} > 3);
  print "ok 12\n";

  # And test alarm order.
  print 'not '
    unless ( $heap->{alarms_eleven}->[ 0] eq 'path_eleven_050' and
             $heap->{alarms_eleven}->[ 1] eq 'path_eleven_075' and
             $heap->{alarms_eleven}->[ 2] eq 'path_eleven_100' and
             $heap->{alarms_eleven}->[ 3] eq 'path_eleven_125' and
             $heap->{alarms_eleven}->[ 4] eq 'path_eleven_150' and
             $heap->{alarms_eleven}->[ 5] eq 'path_eleven_175' and
             $heap->{alarms_eleven}->[ 6] eq 'path_eleven_200' and
             $heap->{alarms_eleven}->[ 7] eq 'path_eleven_201' and
             $heap->{alarms_eleven}->[ 8] eq 'path_eleven_202' and
             $heap->{alarms_eleven}->[ 9] eq 'path_eleven_203' and
             $heap->{alarms_eleven}->[10] eq 'path_eleven_225' and
             $heap->{alarms_eleven}->[11] eq 'path_eleven_250' and
             $heap->{alarms_eleven}->[12] eq 'path_eleven_275' and
             $heap->{alarms_eleven}->[13] eq 'path_eleven_300' and
             $heap->{alarms_eleven}->[14] eq 'path_eleven_325' and
             $heap->{alarms_eleven}->[15] eq 'path_eleven_350'
           );
  print "ok 13\n";
}

sub test_path_one {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if ($test_id == 1.1) {
    $heap->{test}->{path_one} += 1;
  }
  else {
    $heap->{test}->{path_one} += 1000;
  }
}

sub test_path_two {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if ($test_id == 2.2) {
    $heap->{test}->{path_two} += 1;
  }
  else {
    $heap->{test}->{path_two} += 1000;
  }
}

sub test_path_three {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if (($test_id == 3.1) and ($heap->{test}->{path_three} == 0)) {
    $heap->{test}->{path_three} += 1;
  }
  elsif (($test_id == 3.2) and ($heap->{test}->{path_three} == 1)) {
    $heap->{test}->{path_three} += 10;
  }
  else {
    $heap->{test}->{path_three} += 1000;
  }
}

sub test_path_four {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if (($test_id == 4.3) and ($heap->{test}->{path_four} == 0)) {
    $heap->{test}->{path_four} += 1;
  }
  elsif (($test_id == 4.4) and ($heap->{test}->{path_four} == 1)) {
    $heap->{test}->{path_four} += 10;
  }
  else {
    $heap->{test}->{path_four} += 1000;
  }
}

sub test_path_five {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  $heap->{test}->{path_five} += 1;
}

sub test_path_six {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if ($test_id == 6.1) {
    $heap->{test}->{path_six} += 1;
  }
  else {
    $heap->{test}->{path_six} += 1000;
  }
}

sub test_path_seven {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if ($test_id == 7.2) {
    $heap->{test}->{path_seven} += 1;
  }
  else {
    $heap->{test}->{path_seven} += 1000;
  }
}

sub test_path_eight {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if (($test_id == 8.1) and ($heap->{test}->{path_eight} == 0)) {
    $heap->{test}->{path_eight} += 1;
  }
  elsif (($test_id == 8.2) and ($heap->{test}->{path_eight} == 1)) {
    $heap->{test}->{path_eight} += 10;
  }
  else {
    $heap->{test}->{path_eight} += 1000;
  }
}

sub test_path_nine {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  if (($test_id == 9.3) and ($heap->{test}->{path_nine} == 0)) {
    $heap->{test}->{path_nine} += 1;
  }
  elsif (($test_id == 9.4) and ($heap->{test}->{path_nine} == 1)) {
    $heap->{test}->{path_nine} += 10;
  }
  else {
    $heap->{test}->{path_nine} += 1000;
  }
}

sub test_path_ten {
  my ($heap, $test_id) = @_[HEAP, ARG0];

  $heap->{test}->{path_ten} += 1;
}

### Main loop.

print "ok 1\n";

# Spawn a state machine.

POE::Session->create
  ( inline_states =>
    { _start     => \&test_start,
      _stop      => \&test_stop,
      path_one   => \&test_path_one,
      path_two   => \&test_path_two,
      path_three => \&test_path_three,
      path_four  => \&test_path_four,
      path_five  => \&test_path_five,
      path_six   => \&test_path_six,
      path_seven => \&test_path_seven,
      path_eight => \&test_path_eight,
      path_nine  => \&test_path_nine,
      path_ten   => \&test_path_ten,
    }
  );

# Now run it 'til it stops.
$poe_kernel->run();

# Now make sure they've run.

print "ok 14\n";

exit;
