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

use TestSetup;
use TestPipe;

# Skip if Tk isn't here.
BEGIN {
  eval 'use Tk';
  &test_setup(0, 'need the Tk module installed to run this test')
    if ( length($@) or
         not exists($INC{'Tk.pm'})
       );
  }
  # MSWin32 doesn't need DISPLAY set.
  if ($^O ne 'MSWin32') {
    unless ( exists $ENV{'DISPLAY'} and
             defined $ENV{'DISPLAY'} and
             length $ENV{'DISPLAY'}
           ) {
      &test_setup(0, "can't test Tk without a DISPLAY (set one today, ok?)");
    }
  }
};

&test_setup(8);

warn( "\n",
      "***\n",
      "*** Please note: This test will pop up a Tk window.\n",
      "***\n",
    );

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw(Wheel::ReadWrite Filter::Line Driver::SysRW);

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
eval { $poe_tk_main_window->geometry('+10+10') };

# I/O session

sub io_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  # A pipe.

  my ($a_read, $a_write, $b_read, $b_write) = TestPipe->new();

  # Keep a copy of the unused handles so the pipes remain whole.
  $heap->{unused_pipe_1} = $b_read;
  $heap->{unused_pipe_2} = $a_write;
  unless (defined $a_read) {
    print "skip 2 # $@\n";
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
          InputState   => 'ev_pipe_read',
        );

    # And a timer loop to test alarms.
    $kernel->delay( ev_pipe_write => 1 );
  }

  # And counters to monitor read/write progress.

  my $write_count = 0;
  $heap->{write_count} = \$write_count;
  $poe_tk_main_window->Label( -text => 'Write Count' )->pack;
  $poe_tk_main_window->Label( -textvariable => $heap->{write_count} )->pack;

  my $read_count  = 0;
  $heap->{read_count} = \$read_count;
  $poe_tk_main_window->Label( -text => 'Read Count' )->pack;
  $poe_tk_main_window->Label( -textvariable => $heap->{read_count} )->pack;

  # And an idle loop.

  my $idle_count  = 0;
  $heap->{idle_count} = \$idle_count;
  $poe_tk_main_window->Label( -text => 'Idle Count' )->pack;
  $poe_tk_main_window->Label( -textvariable => $heap->{idle_count} )->pack;
  $kernel->yield( 'ev_idle_increment' );

  # And an independent timer loop to test it separately from pipe
  # writer's.

  my $timer_count = 0;
  $heap->{timer_count} = \$timer_count;
  $poe_tk_main_window->Label( -text => 'Timer Count' )->pack;
  $poe_tk_main_window->Label( -textvariable => $heap->{timer_count} )->pack;
  $kernel->delay( ev_timer_increment => 0.5 );

  # Add default postback test results.  They fail if they aren't
  # delivered.

  $heap->{postback_tests} =
  { 5 => "not ok 5\n",
    6 => "not ok 6\n",
    7 => "not ok 7\n",
  };
}

sub io_pipe_write {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{pipe_wheel}->put( scalar localtime );
  if (++${$heap->{write_count}} < $write_max) {
    $kernel->delay( ev_pipe_write => 1 );
  }
  else {
    $after_alarms[5] =
      Tk::After->new( $poe_tk_main_window, 1000, 'once',
                      $_[SESSION]->postback( ev_postback => 5 )
                    );
    undef;
  }
}

sub io_pipe_read {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{read_count}}++;

  # Shut down the wheel if we're done.
  if ( ${$heap->{write_count}} == $write_max ) {
    delete $heap->{pipe_wheel};
  }
}

sub io_idle_increment {
  if (++${$_[HEAP]->{idle_count}} < 10) {
    $_[KERNEL]->yield( 'ev_idle_increment' );
  }
  else {
    $after_alarms[6] =
      Tk::After->new( $poe_tk_main_window, 1000, 'once',
                      $_[SESSION]->postback( ev_postback => 6 )
                    );
    undef;
  }
}

sub io_timer_increment {
  if (++${$_[HEAP]->{timer_count}} < 10) {
    $_[KERNEL]->delay( ev_timer_increment => 0.5 );
  }

  # After the last timer, do a postback to test that (1) postbacks do
  # indeed post back, (2) that they keep a session alive for their
  # duration, and (3) postbacks include the parameters they were
  # given at creation time.

  else {
    $after_alarms[7] =
      Tk::After->new( $poe_tk_main_window, 1000, 'once',
                      $_[SESSION]->postback( ev_postback => 7 )
                    );
    undef;
  }
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

  foreach (sort { $a <=> $b } keys %{$heap->{postback_tests}}) {
    print $heap->{postback_tests}->{$_};
  }
}

# Collect postbacks and cache results.

sub io_postback {
  my ($session, $postback_given) = @_[SESSION, ARG0];
  my $test_number = $postback_given->[0];

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

# Main loop.

$poe_kernel->run();

# Congratulate ourselves on a job completed, regardless of how well it
# was done.
print "ok 8\n";

exit;
