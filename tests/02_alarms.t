#!/usr/bin/perl -w
# $Id$

# Tests alarms.

use strict;

use lib qw(./mylib ../mylib ../lib ./lib);
use TestSetup qw(ok not_ok ok_if ok_unless results test_setup);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

test_setup(30);

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

  # To test duplicates on a small queue.
  my $id_25_3 = $kernel->alarm_set( path_eleven_025_3 => 25 );
  my $id_25_2 = $kernel->alarm_set( path_eleven_025_2 => 25 );
  my $id_25_1 = $kernel->alarm_set( path_eleven_025_1 => 25 );

  # To test micro-updates on a small queue.
  $kernel->alarm_adjust( $id_25_1 => -0.01 ); # negative
  $kernel->alarm_adjust( $id_25_3 =>  0.01 ); # positive

  # Fill the alarm queue to engage the "big queue" binary insert.
  my @eleven_fill;
  for (my $count=0; $count<600; $count++) {
    push @eleven_fill, int(rand(300));
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
  my $id_206 = $kernel->alarm_set( path_eleven_206 => 205 );
  my $id_205 = $kernel->alarm_set( path_eleven_205 => 205 );
  my $id_204 = $kernel->alarm_set( path_eleven_204 => 205 );

  # To test micro-updates on a big queue.
  $kernel->alarm_adjust( $id_204 => -0.01 );  # negative
  $kernel->alarm_adjust( $id_206 =>  0.01 );  # positive

  # Now clear the filler states.
  for (my $count=0; $count<600; $count++) {
    if ($count & 1) {
      $kernel->alarm( "path_eleven_fill_$count" );
    }
    else {
      $kernel->alarm( "path_eleven_fill_$count" );
    }
  }

  # Now acquire the test alarms.
  my @alarms_eleven = grep /^path_eleven_[0-9_]+$/,
    $kernel->queue_peek_alarms();
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

  ok_if(  1, $heap->{test}->{path_one}   == 1  );
  ok_if(  2, $heap->{test}->{path_two}   == 1  );
  ok_if(  3, $heap->{test}->{path_three} == 11 );
  ok_if(  4, $heap->{test}->{path_four}  == 11 );
  ok_if(  5, $heap->{test}->{path_five}  == 1  );
  ok_if(  6, $heap->{test}->{path_six}   == 1  );
  ok_if(  7, $heap->{test}->{path_seven} == 1  );
  ok_if(  8, $heap->{test}->{path_eight} == 11 );
  ok_if(  9, $heap->{test}->{path_nine}  == 11 );
  ok_if( 10, $heap->{test}->{path_ten}   == 1  );

  # Here's where we check the overall run time.  Increased to 5s for
  # extremely slow, overtaxed machines like my NT test platform.
  ok_unless( 11, time() - $heap->{start_time} > 5 );

  # And test alarm order.
  ok_if( 12,
         ( $heap->{alarms_eleven}->[ 0] eq 'path_eleven_025_1' and
           $heap->{alarms_eleven}->[ 1] eq 'path_eleven_025_2' and
           $heap->{alarms_eleven}->[ 2] eq 'path_eleven_025_3' and
           $heap->{alarms_eleven}->[ 3] eq 'path_eleven_050' and
           $heap->{alarms_eleven}->[ 4] eq 'path_eleven_075' and
           $heap->{alarms_eleven}->[ 5] eq 'path_eleven_100' and
           $heap->{alarms_eleven}->[ 6] eq 'path_eleven_125' and
           $heap->{alarms_eleven}->[ 7] eq 'path_eleven_150' and
           $heap->{alarms_eleven}->[ 8] eq 'path_eleven_175' and
           $heap->{alarms_eleven}->[ 9] eq 'path_eleven_200' and
           $heap->{alarms_eleven}->[10] eq 'path_eleven_204' and
           $heap->{alarms_eleven}->[11] eq 'path_eleven_205' and
           $heap->{alarms_eleven}->[12] eq 'path_eleven_206' and
           $heap->{alarms_eleven}->[13] eq 'path_eleven_225' and
           $heap->{alarms_eleven}->[14] eq 'path_eleven_250' and
           $heap->{alarms_eleven}->[15] eq 'path_eleven_275' and
           $heap->{alarms_eleven}->[16] eq 'path_eleven_300' and
           $heap->{alarms_eleven}->[17] eq 'path_eleven_325' and
           $heap->{alarms_eleven}->[18] eq 'path_eleven_350'
         ),
         "@{$heap->{alarms_eleven}}"
       );
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

# Spawn a session to test the functions added in June 2001.

POE::Session->create
  ( inline_states =>
    { _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        $heap->{test_13} = $kernel->alarm_set( test_13 => 1 => 13 );

        my $test_14 = $kernel->alarm_set( test_14 => 1 => 14 );
        my @test_array  = $kernel->alarm_remove( $test_14 );
        ok_if( 14,
               ( $test_array[0] eq 'test_14' and
                 $test_array[1] == 1 and
                 $test_array[2] == 14
               )
               , "one"
             );


        my $test_15 = $kernel->delay_set( test_15 => 1 => 15 );

        # Have time stand still so we can test against it.  Heisenberg
        # strikes again!
        my $now = time;

        my $test_scalar = $kernel->alarm_remove( $test_15 );
        ok_if( 15,
               ( $test_scalar->[0] eq 'test_15' and
                 $test_scalar->[1] <= $now+2 and
                 $test_scalar->[1] >= $now-2 and
                 $test_scalar->[2] == 15
               )
               , "one"
             );
      },

      # This one is dispatched.
      test_13 => sub {
        my $kernel = $_[KERNEL];

        ok_if( 13, $_[ARG0]==13 );

        # Set a couple alarms, then clear them all.
        $kernel->delay( test_16 => 1 );
        $kernel->delay( test_17 => 1 );
        $kernel->alarm_remove_all();

        # Test alarm adjusting on little queues.
        my $alarm_id = $kernel->alarm_set( test_18 => 50 => 18 );

        # One alarm.
        my $new_time = $kernel->alarm_adjust( $alarm_id => -1 );
        ok_if( 18, $new_time == 49 );

        $new_time = $kernel->alarm_adjust( $alarm_id => 1 );
        ok_if( 19, $new_time == 50 );

        # Two alarms.
        $alarm_id = $kernel->alarm_set( test_19 => 52 => 19 );
        $new_time = $kernel->alarm_adjust( $alarm_id => -4 );
        ok_if( 20, $new_time == 48 );

        $new_time = $kernel->alarm_adjust( $alarm_id => 4 );
        ok_if( 21, $new_time == 52 );

        # Three alarms.
        $alarm_id = $kernel->alarm_set( test_20 => 49 => 20 );
        $new_time = $kernel->alarm_adjust( $alarm_id => 2 );
        ok_if( 22, $new_time == 51 );

        $new_time = $kernel->alarm_adjust( $alarm_id => 2 );
        ok_if( 23, $new_time == 53 );

        $new_time = $kernel->alarm_adjust( $alarm_id => -2 );
        ok_if( 24, $new_time == 51 );

        # Test alarm adjusting on big queues.
        my @alarm_filler;
        for (1..100) {
          push( @alarm_filler, $kernel->alarm_set( filler => $_) );
        }

        # Moving inside the alarm range.
        $alarm_id = $kernel->alarm_set( test_21 => 50 => 21 );
        $new_time = $kernel->alarm_adjust( $alarm_id => -10 );
        ok_if( 25, $new_time == 40 );

        $new_time = $kernel->alarm_adjust( $alarm_id => 20 );
        ok_if( 26, $new_time == 60 );

        # Moving outside (to the beginning) of the alarm range.
        $new_time = $kernel->alarm_adjust( $alarm_id => -100 );
        ok_if( 27, $new_time == -40 );

        # Moving outside (to the end) of the alarm range.
        $alarm_id = $kernel->alarm_set( test_22 => 50 => 22 );
        $new_time = $kernel->alarm_adjust( $alarm_id => 100 );
        ok_if( 28, $new_time == 150 );

        # Remove the filler events.
        foreach (@alarm_filler) {
          $kernel->alarm_remove( $_ );
        }
      },

      # These have been removed.  They should not be dispatched.
      test_14 => sub { not_ok(14); },
      test_15 => sub { not_ok(15); },
      test_16 => sub { $_[HEAP]->{test_16_failed} = 1; },
      test_17 => sub { $_[HEAP]->{test_17_failed} = 1; },

      # These should be dispatched in a certain order.
      _default => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Save the test's argument on the heap. Check during _stop.
        push( @{$heap->{tests}}, $_[ARG1]->[0] ) if $_[ARG0] =~ /test_\d+/;

        # Handle the signal.
        $kernel->sig_handled();
      },

      _stop => sub {
        my $heap = $_[HEAP];
        ok_unless( 16, $heap->{test_16_failed} );
        ok_unless( 17, $heap->{test_16_failed} );

        ok_if( 29,
               ( @{$heap->{tests}} == 5 and
                 $heap->{tests}->[0] == 21 and
                 $heap->{tests}->[1] == 18 and
                 $heap->{tests}->[2] == 20 and
                 $heap->{tests}->[3] == 19 and
                 $heap->{tests}->[4] == 22
               )
             );

        # Spawn a state machine to test the older interface.  Yes,
        # this spawns a new state machine from the death throes of an
        # old one.

        POE::Session->create
          ( inline_states =>
            { _start      => \&test_start,
              _stop       => \&test_stop,
              _default => sub { },
              path_one    => \&test_path_one,
              path_two    => \&test_path_two,
              path_three  => \&test_path_three,
              path_four   => \&test_path_four,
              path_five   => \&test_path_five,
              path_six    => \&test_path_six,
              path_seven  => \&test_path_seven,
              path_eight  => \&test_path_eight,
              path_nine   => \&test_path_nine,
              path_ten    => \&test_path_ten,
            }
          );

      },
    }
  );

# Now run it 'til it stops.
$poe_kernel->run();

# Now make sure they've run.
ok(30);

results();

exit;
