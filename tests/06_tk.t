#!/usr/bin/perl -w
# $Id$

# Tests FIFO, alarm, select and Tk postback events using Tk's event
# loop.

use strict;

use lib qw(./lib ../lib);

use Symbol;
use TestSetup;

# Skip if Tk isn't here or if environmental requirements don't apply.
BEGIN {
  eval 'use Tk';
  &test_setup(0, "Tk is needed for these tests")
    if ( length($@) or
         not exists($INC{'Tk.pm'})
       );

  # MSWin32 doesn't need DISPLAY set.
  if ($^O ne "MSWin32") {
    unless ( exists $ENV{'DISPLAY'} and
             defined $ENV{'DISPLAY'} and
             length $ENV{'DISPLAY'}
           ) {
      &test_setup(0, "Can't test Tk without a DISPLAY. (Set one today, ok?)");
    }
  }

  # Tk support relies on an interface change that occurred in 800.021.
  &test_setup(0, "Tk 800.021 or newer is needed for these tests")
    if $Tk::VERSION < 800.021;

  # Tk and Perl before 5.005_03 don't mix.
  &test_setup( 0, "Tk requires Perl 5.005_03 or newer." ) if $] < 5.005_03;
};

&test_setup(11);

warn( "\n",
      "***\n",
      "*** Please note: This test will pop up a window or two.\n",
      "***\n",
    );

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw(Wheel::ReadWrite Filter::Line Driver::SysRW Pipe::TwoWay);

# How many things to push through the pipe.
my $write_max = 10;

# Keep track of the "after" alarms we use so the postback tests can
# clear them.
my @after_alarms;

# Congratulate ourselves for getting this far.
print "ok 1\n";

# Attempt to set the window position.  This was borrowed from one of
# Tk's own tests.  It glues the window into place so the program can
# continue.  This may be unfriendly, but it minimizes the amount of
# user interaction needed to perform this test.
eval { $poe_main_window->geometry('+10+10') };

# I/O session

sub io_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # A pipe.

  my ($a_read, $a_write, $b_read, $b_write) = POE::Pipe::TwoWay->new();

  if (defined $a_read) {
    # The wheel uses read and write file events internally, so they're
    # tested here.
    $heap->{a_pipe_wheel} =
      POE::Wheel::ReadWrite->new
        ( InputHandle  => $a_read,
          OutputHandle => $a_write,
          Filter       => POE::Filter::Line->new(),
          # Use default driver.
          InputEvent   => 'ev_a_read',
        );

    # Second wheel to test a fileevent quirk.
    $heap->{b_pipe_wheel} =
      POE::Wheel::ReadWrite->new
        ( InputHandle  => $b_read,
          OutputHandle => $b_write,
          # Use default filter.
          Driver       => POE::Driver::SysRW->new(),
          InputEvent   => 'ev_b_read',
        );

    # And a timer loop to test alarms.
    $kernel->delay( ev_pipe_write => 1 );

    # Add a timer to time-out the test.
    $kernel->delay( ev_timeout => 15 );
  }

  # And counters to monitor read/write progress.

  my $write_count = 0;
  $heap->{write_count} = \$write_count;
  $poe_main_window->Label( -text => 'Write Count' )->pack;
  $poe_main_window->Label( -textvariable => $heap->{write_count} )->pack;

  my $a_read_count = 0;
  $heap->{a_read_count} = \$a_read_count;
  $poe_main_window->Label( -text => 'Read Count' )->pack;
  $poe_main_window->Label( -textvariable => $heap->{a_read_count} )->pack;

  my $b_read_count = 0;
  $heap->{b_read_count} = \$b_read_count;
  $poe_main_window->Label( -text => 'Read Count' )->pack;
  $poe_main_window->Label( -textvariable => $heap->{b_read_count} )->pack;

  # And an idle loop.

  my $idle_count  = 0;
  $heap->{idle_count} = \$idle_count;
  $poe_main_window->Label( -text => 'Idle Count' )->pack;
  $poe_main_window->Label( -textvariable => $heap->{idle_count} )->pack;
  $kernel->yield( 'ev_idle_increment' );

  # And an independent timer loop to test it separately from pipe
  # writer's.

  my $timer_count = 0;
  $heap->{timer_count} = \$timer_count;
  $poe_main_window->Label( -text => 'Timer Count' )->pack;
  $poe_main_window->Label( -textvariable => $heap->{timer_count} )->pack;
  $kernel->delay( ev_timer_increment => 0.5 );

  # Add default postback test results.  They fail if they aren't
  # delivered.

  $heap->{postback_tests} =
  { 6 => "not ok 6\n",
    7 => "not ok 7\n",
    8 => "not ok 8\n",
  };
}

sub io_pipe_write {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{a_pipe_wheel}->put( scalar localtime );
  $heap->{b_pipe_wheel}->put( scalar localtime );
  $kernel->delay( ev_timeout => 1 );
  if (++${$heap->{write_count}} < $write_max) {
    $kernel->delay( ev_pipe_write => 0.25 );
  }
  else {
    $after_alarms[6] =
      Tk::After->new( $poe_main_window, 500, 'once',
                      $_[SESSION]->postback( ev_postback => 6 )
                    );
    undef;
  }
}

# This is a plain function; not an event handler.
sub shut_down_if_done {
  my $heap = shift;  # It's ok.  It's a plain function, not an event handler.

  # Shut down both wheels if we're done.
  if ( ${$heap->{a_read_count}} == $write_max and
       ${$heap->{b_read_count}} == $write_max
     ) {
    delete $heap->{a_pipe_wheel};
    delete $heap->{b_pipe_wheel};
  }
}

sub io_a_read {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{a_read_count}}++;
  $kernel->delay( ev_timeout => 1 );
  shut_down_if_done($heap);
}

sub io_b_read {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{b_read_count}}++;
  $kernel->delay( ev_timeout => 1 );
  &shut_down_if_done($heap);
}

sub io_idle_increment {
  $_[KERNEL]->delay( ev_timeout => 1 );
  if (++${$_[HEAP]->{idle_count}} < 10) {
    $_[KERNEL]->yield( 'ev_idle_increment' );
  }
  else {
    $after_alarms[7] =
      Tk::After->new( $poe_main_window, 500, 'once',
                      $_[SESSION]->postback( ev_postback => 7 )
                    );
    undef;
  }
}

sub io_timer_increment {
  $_[KERNEL]->delay( ev_timeout => 1 );

  if (++${$_[HEAP]->{timer_count}} < 10) {
    $_[KERNEL]->delay( ev_timer_increment => 0.5 );
  }

  # After the last timer, do a postback to test that (1) postbacks do
  # indeed post back, (2) that they keep a session alive for their
  # duration, and (3) postbacks include the parameters they were
  # given at creation time.

  else {
    $after_alarms[8] =
      Tk::After->new( $poe_main_window, 500, 'once',
                      $_[SESSION]->postback( ev_postback => 8 )
                    );
    undef;
  }
}

sub io_stop {
  my $heap = $_[HEAP];

  my $a_ref = $heap->{a_read_count};
  my $b_ref = $heap->{b_read_count};
  my $w_ref = $heap->{write_count};

  # If a != w, then it failed.
  # But if a == 0 and MSWin32, then skip

  my $reason = "";
  if ($$a_ref != $$w_ref) {
    if ($^O eq "MSWin32") {
      if ($$a_ref) {
        print "not ";
      }
      else {
        $reason = " # skipped: Tk $Tk::VERSION fileevent is broken on $^O.";
      }
    }
    else {
      print "not ";
    }
  }
  print "ok 2$reason\n";

  $reason = "";
  if ($$a_ref != $$w_ref) {
    if ($^O eq "MSWin32") {
      if ($$a_ref) {
        print "not ";
      }
      else {
        $reason = " # skipped: $^O does not support Tk $Tk::VERSION.";
      }
    }
    else {
      print "not ";
    }
  }
  print "ok 3$reason\n";

  print "not " unless ${$heap->{idle_count}};
  print "ok 4\n";

  print "not " unless ${$heap->{timer_count}};
  print "ok 5\n";

  foreach (sort { $a <=> $b } keys %{$heap->{postback_tests}}) {
    print $heap->{postback_tests}->{$_};
  }
}

# Collect postbacks and cache results.

sub io_postback {
  my ($session, $postback_given) = @_[SESSION, ARG0];
  my $test_number = $postback_given->[0];

  $_[KERNEL]->delay( ev_timeout => 1 );

  if ($test_number =~ /^\d+$/) {

    # This is so incredibly horribly bad that I'm ashamed to be doing
    # it.  First we violate the Tk::After object to get at the
    # Tk::Callback object within it.  Then we violate THAT to remove
    # the POE::Session::Postback so that it's destroyed and our
    # reference count decrements.
    $after_alarms[$test_number]->[4]->[0] = undef;

    $_[HEAP]->{postback_tests}->{$test_number} = "ok $test_number\n";
  }
}

# The tests have timed out; close down.

sub io_timeout {
  my $heap = $_[HEAP];
  delete $heap->{a_pipe_wheel};
  delete $heap->{b_pipe_wheel};
}

# Start the I/O session.

POE::Session->create
  ( inline_states =>
    { _start             => \&io_start,
      _stop              => \&io_stop,
      ev_a_read          => \&io_a_read,
      ev_b_read          => \&io_b_read,
      ev_pipe_write      => \&io_pipe_write,
      ev_idle_increment  => \&io_idle_increment,
      ev_timer_increment => \&io_timer_increment,
      ev_postback        => \&io_postback,
      ev_timeout         => \&io_timeout,
    }
  );

# First main loop.
$poe_kernel->run();
print "ok 9\n";

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
        print "ok 10\n";
      },
    }
  );

# Verify that the main loop can run yet again.
$poe_kernel->run();
print "ok 11\n";
exit;
