#!/usr/bin/perl -w
# $Id$

# Tests FIFO, alarm, select and Gtk postback events using Gk's event
# loop.

use strict;
use lib qw(./mylib ../mylib .. .);

use Symbol;

use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }


# Skip if Gtk isn't here.
BEGIN {
  eval 'use Gtk';
  &test_setup(0, "Gtk is needed for these tests.")
    if ( length($@) or
         not exists($INC{'Gtk.pm'})
       );
  # MSWin32 doesn't need DISPLAY set.
  if ($^O ne 'MSWin32') {
    unless ( exists $ENV{'DISPLAY'} and
             defined $ENV{'DISPLAY'} and
             length $ENV{'DISPLAY'}
           ) {
      &test_setup(0, "Can't test Gtk without a DISPLAY. (Set one today, ok?)");
    }
  }
};

# Check if Gtk can connect to a display and do its usual init type things
# Skip if gtk finds a problem with the setup
BEGIN {
  eval {
    require POE::Kernel;
  };
  if ($@ and $@ =~ /initialization failed/) {
    test_setup(0, "Gtk initialization failed. Probably can't connect to a display.");
  } 
}


&test_setup(10);

warn( "\n",
      "***\n",
      "*** Please note: This test will pop up a window.\n",
      "***\n",
    );
use POE qw(Wheel::ReadWrite Filter::Line Driver::SysRW Pipe::OneWay);

# How many things to push through the pipe.
my $write_max = 10;

# Keep track of the "after" alarms we use so the postback tests can
# clear them.
my @after_alarms;

# Congratulate ourselves for getting this far.
print "ok 1\n";

# I/O session

sub io_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # A pipe.

  my ($a_read, $b_write) = POE::Pipe::OneWay->new();

  # Keep a copy of the unused handles so the pipes remain whole.
  unless (defined $a_read) {
    print "ok 2 # skipped: Could not create a pipe in any form.\n";
  }
  else {
    # The wheel uses read and write file events internally, so they're
    # tested here.
    $heap->{pipe_wheel} =
      POE::Wheel::ReadWrite->new
        ( InputHandle  => $heap->{pipe_read}  = $a_read,
          OutputHandle => $heap->{pipe_write} = $b_write,
          Filter       => POE::Filter::Line->new(),
          Driver       => POE::Driver::SysRW->new(),
          InputEvent   => 'ev_pipe_read',
        );

    # And a timer loop to test alarms.
    $kernel->delay( ev_pipe_write => 1 );
  }

  # Start a main window.  POE stopped doing this for you in version
  # 0.1207.

  $heap->{main_window} = Gtk::Window->new('toplevel');
  $kernel->signal_ui_destroy( $heap->{main_window} );

  # And counters to monitor read/write progress.

  my $box = Gtk::VBox->new(0, 0);
  $heap->{main_window}->add($box);
  $box->show();

  { my $label = Gtk::Label->new( 'Write Count' );
    $box->pack_start( $label, 1, 1, 0 );
    $label->show();

    $heap->{write_count} = 0;
    $heap->{write_label} = Gtk::Label->new( $heap->{write_count} );
    $box->pack_start( $heap->{write_label}, 1, 1, 0 );
    $heap->{write_label}->show();
  }

  { my $label = Gtk::Label->new( 'Read Count' );
    $box->pack_start( $label, 1, 1, 0 );
    $label->show();

    $heap->{read_count} = 0;
    $heap->{read_label} = Gtk::Label->new( $heap->{read_count} );
    $box->pack_start( $heap->{read_label}, 1, 1, 0 );
    $heap->{read_label}->show();
  }

  # And an idle loop.

  { my $label = Gtk::Label->new( 'Idle Count' );
    $box->pack_start( $label, 1, 1, 0 );
    $label->show();

    $heap->{idle_count} = 0;
    $heap->{idle_label} = Gtk::Label->new( $heap->{idle_count} );
    $box->pack_start( $heap->{idle_label}, 1, 1, 0 );
    $heap->{idle_label}->show();

    $kernel->yield( 'ev_idle_increment' );
  }

  # And an independent timer loop to test it separately from pipe
  # writer's.

  { my $label = Gtk::Label->new( 'Timer Count' );
    $box->pack_start( $label, 1, 1, 0 );
    $label->show();

    $heap->{timer_count} = 0;
    $heap->{timer_label} = Gtk::Label->new( $heap->{timer_count} );
    $box->pack_start( $heap->{timer_label}, 1, 1, 0 );
    $heap->{timer_label}->show();

    $kernel->delay( ev_timer_increment => 0.5 );
  }

  # Add default postback test results.  They fail if they aren't
  # delivered.

  $heap->{postback_tests} =
  { 5 => "not ok 5\n",
    6 => "not ok 6\n",
    7 => "not ok 7\n",
  };

  $heap->{main_window}->show();
}

sub io_pipe_write {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{pipe_wheel}->put( scalar localtime );
  $heap->{write_label}->set_text( ++$heap->{write_count} );

  if ($heap->{write_count} < $write_max) {
    $kernel->delay( ev_pipe_write => 0.25 );
  }
  else {
    Gtk->timeout_add( 500, $_[SESSION]->postback( ev_postback => 5 ) );
  }
}

sub io_pipe_read {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{read_label}->set_text( ++$heap->{read_count} );

  # Shut down the wheel if we're done.
  if ( $heap->{write_count} == $write_max ) {
    delete $heap->{pipe_wheel};
  }
}

sub io_idle_increment {
  $_[HEAP]->{idle_label}->set_text( ++$_[HEAP]->{idle_count} );

  if ($_[HEAP]->{idle_count} < 10) {
    $_[KERNEL]->yield( 'ev_idle_increment' );
  }
  else {
    Gtk->timeout_add( 500, $_[SESSION]->postback( ev_postback => 6 ) );
    undef;
  }
}

sub io_timer_increment {
  $_[HEAP]->{timer_label}->set_text( ++$_[HEAP]->{timer_count} );

  if ($_[HEAP]->{timer_count} < 10) {
    $_[KERNEL]->delay( ev_timer_increment => 0.5 );
  }

  # After the last timer, do a postback to test that (1) postbacks do
  # indeed post back, (2) that they keep a session alive for their
  # duration, and (3) postbacks include the parameters they were
  # given at creation time.

  else {
    Gtk->timeout_add( 500, $_[SESSION]->postback( ev_postback => 7 ) );
    undef;
  }
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

  foreach (sort { $a <=> $b } keys %{$heap->{postback_tests}}) {
    print $heap->{postback_tests}->{$_};
  }
}

# Collect postbacks and cache results.  We only expect three, so try
# to force the program closed when we get them.

sub io_postback {
  my ($kernel, $session, $postback_given) = @_[KERNEL, SESSION, ARG0];
  my $test_number = $postback_given->[0];

  if ($test_number =~ /^\d+$/) {
    $_[HEAP]->{postback_tests}->{$test_number} = "ok $test_number\n";
  }
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
      ev_postback        => \&io_postback,
    }
  );

# First main loop.
$poe_kernel->run();
print "ok 8\n";

# Try re-running the main loop.
POE::Session->create
  ( inline_states =>
    { _start => sub {
        $_[HEAP]->{count} = 0;
        $_[KERNEL]->yield("increment");
      },
      increment => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];
        if ($heap->{count} < 10) {
          $kernel->yield("increment");
          $heap->{count}++;
        }
      },
      _stop => sub {
        print "not " unless $_[HEAP]->{count} == 10;
        print "ok 9\n";
      },
    }
  );

# Verify that the main loop can run yet again.
$poe_kernel->run();
print "ok 10\n";

exit;
