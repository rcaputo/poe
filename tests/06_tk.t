#!/usr/bin/perl -w
# $Id$

# Tests FIFO, alarm, select and Tk postback events using Tk's event
# loop.

use strict;
use lib qw(./lib ../lib);
use lib '/usr/mysrc/Tk800.021/blib';
use lib '/usr/mysrc/Tk800.021/blib/lib';
use lib '/usr/mysrc/Tk800.021/blib/arch';
use Symbol;

use TestSetup qw(5);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

# Skip if Tk isn't here.
BEGIN {
  eval 'use Tk';
  unless (exists $INC{'Tk.pm'}) {
    for (my $test=1; $test <= 1; $test++) {
      print "skip $test # no Tk support\n";
    }
    exit 0;
  }
}

use POE qw(Wheel::ReadWrite Filter::Line Driver::SysRW);

# Congratulate ourselves for getting this far.
print "ok 1\n";

# Attempt to set the window position.  This was borrowed from one of
# Tk's own tests.  It glues the window into place so the program can
# continue.  This may be unfriendly, but it minimizes the amount of
# user interaction needed to perform this test.
eval { $poe_tk_main_window->geometry('+10+10') };

# I/O session

sub io_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # A pipe.

  $heap->{pipe_read}  = gensym();
  $heap->{pipe_write} = gensym();

  eval {
    pipe($heap->{pipe_read}, $heap->{pipe_write})
      or die "can't create pipe: $!";
  };

  # Can't test file events.

  if ($@ eq '') {
    print "skip 2 # $@\n";
  }

  else {
    # The wheel uses read and write file events internall, so they're
    # tested here.
    $heap->{pipe_wheel} =
      POE::Wheel::ReadWrite->new
        ( InputHandle  => $heap->{pipe_read},
          OutputHandle => $heap->{pipe_write},
          Filter       => POE::Filter::Line->new(),
          Driver       => POE::Driver::SysRW->new(),
          InputState   => 'ev_pipe_read',
        );

    # And a timer loop to test alarms.
    $kernel->delay( ev_pipe_write => 1 );
  }

  # And counters to monitor read/write progress.

  my $write_count = 0;
  $heap->{write_count} = \$write_count;
  $poe_tk_main_window->Label( -textvariable => $heap->{write_count} );

  my $read_count  = 0;
  $heap->{read_count} = \$read_count;
  $poe_tk_main_window->Label( -textvariable => $heap->{read_count} );

  # And an idle loop.

  my $idle_count  = 0;
  $heap->{idle_count} = \$idle_count;
  $poe_tk_main_window->Label( -textvariable => $heap->{idle_count} );
  $kernel->yield( 'ev_idle_increment' );

  # And an independent timer loop to test it separately from pipe
  # writer's.

  my $timer_count = 0;
  $heap->{timer_count} = \$timer_count;
  $poe_tk_main_window->Label( -textvariable => $heap->{timer_count} );
  $kernel->delay( ev_timer_increment => 0.5 );
}

sub io_pipe_write {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{pipe_wheel}->put( scalar localtime );
  $kernel->delay( ev_pipe_write => 1 ) if ++${$heap->{write_count}} < 10;
}

sub io_pipe_read {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{read_count}}++;

  # Shut down the wheel if we're done.
  delete $heap->{pipe_wheel} if ${$heap->{write_count}} == 10;
}

sub io_idle_increment {
  ${$_[HEAP]->{idle_count}}++;
  $_[KERNEL]->yield( 'ev_idle_increment' );
}

sub io_timer_increment {
  ${$_[HEAP]->{timer_count}}++;
  $_[KERNEL]->yield( 'ev_timer_increment' );
}

sub io_stop {
  my $heap = $_[HEAP];

  if (${$heap->{read_count}}) {
    print "not " unless ${$heap->{read_count}} == ${$heap->{write_count}};
    print "ok 2\n";
  }

  print "not " unless ${$heap->{idle_count}};
  print "ok 3\n";

  print "not " unless ${$heap->{timer_count}};
  print "ok 4\n";
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
    }
  );

# Main loop.

$poe_kernel->run();

# Congratulate ourselves on a job completed, regardless of how well it
# was done.
print "ok 5\n";

exit;

__END__

sub ui_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];



  # Some scalars from which we'll be making anonymous references.
  my $fast_text = 0;
  my $slow_text = 0;
  my $idle_text = 0;

  # A pipe.

  $heap->{pipe_read}  = gensym();
  $heap->{pipe_write} = gensym();
  pipe($heap->{pipe_read}, $heap->{pipe_write}) or die "can't create pipe: $!";

  $heap->{pipe_wheel} =
    POE::Wheel::ReadWrite->new
      ( InputHandle  => $heap->{pipe_read},
        OutputHandle => $heap->{pipe_write},
        Filter       => POE::Filter::Line->new(),
        Driver       => POE::Driver::SysRW->new(),
        InputState   => 'ev_pipe_read',
        ErrorState   => 'ev_pipe_error',
      );

  # An entry field.  Things entered here are written to the writable
  # end of the pipe.

  $heap->{pipe_entry} = $poe_tk_main_window->Entry( -width => 30 );
  $heap->{pipe_entry}->insert( 0, scalar localtime() );
  $heap->{pipe_entry}->pack;

  # A button.  Pressing it writes what's in the entry field into the
  # pipe.

  $poe_tk_main_window->Button
    ( -text => 'Write Entry to Pipe',
      -command => $session->postback( 'ev_pipe_write' )
    )->pack;

  # A listbox.  It contains the last 5 things fetched from the
  # readable end of the pipe.

  $heap->{pipe_tail_list} = $poe_tk_main_window->Listbox
    ( -height => 5, -width => 30
    );
  for my $i (0..4) {
    $heap->{pipe_tail_list}->insert( 'end', "starting line $i" );
  }
  $heap->{pipe_tail_list}->pack;

  # A fast timed counter.

  $heap->{fast_text} = \$fast_text;
  $heap->{fast_widget} =
    $poe_tk_main_window->Label( -textvariable => $heap->{fast_text} );
  $heap->{fast_widget}->pack;

  # A slow timed counter.

  $heap->{slow_text} = \$slow_text;
  $heap->{slow_widget} =
    $poe_tk_main_window->Label( -textvariable => $heap->{slow_text} );
  $heap->{slow_widget}->pack;

  # An idle counter.

  $heap->{idle_text} = \$idle_text;
  $heap->{idle_widget} =
    $poe_tk_main_window->Label( -textvariable => $heap->{idle_text} );
  $heap->{idle_widget}->pack;

  # Buttons to start and stop the timed counters.

  $poe_tk_main_window->Button
    ( -text => 'Begin Slow and Fast Alarm Counters',
      -command => $session->postback( 'ev_counters_begin' )
    )->pack;
  $poe_tk_main_window->Button
    ( -text => 'Stop Slow and Fast Alarm Counters',
      -command => $session->postback( 'ev_counters_cease' )
    )->pack;

  # A button to exit the program would be nice! :)

  $poe_tk_main_window->Button
    ( -text => 'Exit',
      -command => sub { $poe_tk_main_window->destroy }
    )->pack;

  # Begin some callbacks.

  $poe_tk_main_window->bind( '<FocusIn>',
                             $session->postback( 'ev_idle_count_begin' )
                           );

  $poe_tk_main_window->bind( '<FocusOut>',
                             $session->postback( 'ev_idle_count_cease' )
                           );
}

sub ui_stop {
  print "Session ", $_[SESSION]->ID, " is stopped.\n";
}

sub ui_signal {
  my ($session, $signal) = @_[SESSION, ARG0];
  print "Session ", $session->ID, " caught signal $signal.\n";
}

### Timed counters logic.

sub ui_slow_counter_increment {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{slow_text}}++;
  $kernel->delay( 'ev_slow_count', 0.2 );
}

sub ui_fast_counter_increment {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{fast_text}}++;
  $kernel->delay( 'ev_fast_count', 0.1 );
}

sub ui_timed_counters_begin {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  unless ($heap->{timers_running}) {
    $heap->{timers_running} = 1;
    $kernel->delay( 'ev_fast_count', 0.1 );
    $kernel->delay( 'ev_slow_count', 0.2 );
  }
}

sub ui_timed_counters_cease {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  if ($heap->{timers_running}) {
    $heap->{timers_running} = 0;
    $kernel->delay( 'ev_fast_count' );
    $kernel->delay( 'ev_slow_count' );
  }
}

### Focused idle counter.

sub ui_focus_idle_counter_begin {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  unless ($heap->{has_focus}) {
    $heap->{has_focus} = 1;
    $kernel->yield( 'ev_idle_count' );
  }
}

sub ui_focus_idle_counter_cease {
  $_[HEAP]->{has_focus} = 0;
}

sub ui_focus_idle_counter_increment {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  if ($heap->{has_focus}) {
    ${$heap->{idle_text}}++;
    $kernel->yield( 'ev_idle_count' );
  }
}

### Select stuff.

sub ui_ev_pipe_write {
  my $heap = $_[HEAP];
  my $text = $heap->{pipe_entry}->get();
  $heap->{pipe_entry}->delete( 0, length($text) );
  $heap->{pipe_entry}->insert( 0, scalar localtime() );
  $heap->{pipe_wheel}->put($text);
}

sub ui_ev_pipe_read {
  my ($heap, $line) = @_[HEAP, ARG0];

  $heap->{pipe_tail_list}->delete(0);
  $heap->{pipe_tail_list}->insert( 'end', $line );
}

sub ui_ev_pipe_error {
  my ($heap, $op, $en, $es) = @_[HEAP, ARG0..ARG2];
  $heap->{pipe_tail_list}->delete(0);
  $heap->{pipe_tail_list}->insert( 'end', "pipe got $op error $en: $es" );
}

### Main loop, or something.

POE::Session->create
  ( inline_states =>
    { _start  => \&ui_start,
      _stop   => \&ui_stop,
      _signal => \&ui_signal,

      ### Timed counters states, including buttons.

      ev_counters_begin => \&ui_timed_counters_begin,
      ev_counters_cease => \&ui_timed_counters_cease,
      ev_fast_count     => \&ui_fast_counter_increment,
      ev_slow_count     => \&ui_slow_counter_increment,

      ### Idle counter states.

      ev_idle_count       => \&ui_focus_idle_counter_increment,
      ev_idle_count_begin => \&ui_focus_idle_counter_begin,
      ev_idle_count_cease => \&ui_focus_idle_counter_cease,

      ### Pipe watcher.

      ev_pipe_error => \&ui_ev_pipe_error,
      ev_pipe_read  => \&ui_ev_pipe_read,
      ev_pipe_write => \&ui_ev_pipe_write,
    }
  );


