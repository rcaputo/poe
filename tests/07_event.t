#!/usr/bin/perl -w
# $Id$

# Tests FIFO, alarm, select and postback events using Event's event
# loop.

use strict;
use lib qw(./lib ../lib);
use Symbol;

use TestSetup;

# Skip if Event isn't here.
BEGIN {
  eval 'use Event';
  &test_setup(0, 'need the Event module installed to run this test')
    if ( length($@) or
         not exists($INC{'Event.pm'})
       );
};

&test_setup(6);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Session::ASSERT_STATES () { 0 }
use POE qw(Wheel::ReadWrite Filter::Line Driver::SysRW Pipe::OneWay);

# Congratulate ourselves for getting this far.
print "ok 1\n";

# I/O session

sub io_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # A pipe.

  my ($a_read, $b_write) = POE::Pipe::OneWay->new();
  unless (defined $a_read) {
    print "skip 2 # $@\n";
  }
  else {
    # The wheel uses read and write file events internall, so they're
    # tested here.
    $heap->{pipe_wheel} =
      POE::Wheel::ReadWrite->new
        ( InputHandle  => $heap->{pipe_read}  = $a_read,
          OutputHandle => $heap->{pipe_write} = $b_write,
          # Use default filter.
          # Use default driver.
          InputEvent   => 'ev_pipe_read',
        );

    # And a timer loop to test alarms.
    $kernel->delay( ev_pipe_write => 1 );
  }

  # And counters to monitor read/write progress.

  $heap->{write_count} = 0;
  $heap->{read_count}  = 0;

  # And an idle loop.

  $heap->{idle_count} = 0;
  $kernel->yield( 'ev_idle_increment' );

  # And a signal count.

  $heap->{signal_count} = 0;
  $kernel->sig( USR1 => 'ev_sig_usr1' );

  # And an independent timer loop to test it separately from pipe
  # writer's.

  $heap->{timer_count} = 0;
  $kernel->delay( ev_timer_increment => 0.5 );
}

sub io_pipe_write {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{pipe_wheel}->put( scalar localtime );
  $kernel->delay( ev_pipe_write => 0.25 ) if ++$heap->{write_count} < 10;
}

sub io_pipe_read {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{read_count}++;

  # Shut down the wheel if we're done.
  delete $heap->{pipe_wheel} if $heap->{write_count} == 10;
}

sub io_idle_increment {
  if (++$_[HEAP]->{idle_count} < 10) {
    $_[KERNEL]->yield( 'ev_idle_increment' );
  }
}

sub io_timer_increment {
  kill 'USR1', $$;
  if (++$_[HEAP]->{timer_count} < 10) {
    $_[KERNEL]->delay( ev_timer_increment => 0.5 );
  }

  # One last timer, going nowhere, to keep the session alive long
  # enough to catch the last signal.
  else {
    $_[KERNEL]->delay( nonexistent_state => 0.5 );
  }
}

sub io_sig_usr1 {
  $_[HEAP]->{signal_count}++ if $_[ARG0] eq 'USR1';
  $_[KERNEL]->sig_handled();
}

sub io_stop {
  my $heap = $_[HEAP];

  if ($heap->{read_count}) {
    print "not " unless $heap->{read_count} == $heap->{write_count};
    print "ok 2\n";
  }

  print "not " unless $heap->{idle_count};
  print "ok 3\n";

  print "not " unless $heap->{timer_count};
  print "ok 4\n";

  print "not " unless $heap->{signal_count} == $heap->{timer_count};
  print "ok 5\n";

  # Remove the signal, just to make sure that code runs.
  $_[KERNEL]->sig( 'USR1' );
}

# Start the I/O session.

POE::Session->create
  ( inline_states =>
    { _start             => \&io_start,
      _stop              => \&io_stop,
      ev_pipe_read       => \&io_pipe_read,
      ev_pipe_write      => \&io_pipe_write,
      ev_idle_increment  => \&io_idle_increment,
      ev_timer_increment => \&io_timer_increment,
      ev_sig_usr1        => \&io_sig_usr1,
    },
  );

# Main loop.

$poe_kernel->run();

# Congratulate ourselves on a job completed, regardless of how well it
# was done.
print "ok 6\n";

exit;
