#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

# This regression test verifies what happens when the following
# happens in between two polls of a log file:
#
# 1. A log file is rolled by being renamed out of the way.
# 2. The new log is created by appending to the original file location.
#
# The desired result is the first log lines are fetched to completion
# before the new log is opened.  No data is lost in this case.

use strict;
use warnings;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use Test::More;
use POE qw(Wheel::FollowTail);

use constant LOG     => 'test_log';
use constant OLD_LOG => 'test_log.1';

# TODO - Perhaps POE::Wheel::FollowTail should close its file at the
# end of a poll and reopen it at the start of the next?  At least on
# silly systems like DOS^H^H^HWindows?

{
  open my $fh, '>>', LOG or die "open failed: $!";
  unless (rename LOG, OLD_LOG) {
    plan skip_all => "$^O cannot rename files that are open";
  }
  close $fh;
  unlink LOG, OLD_LOG;
}

my @expected_results = (
  [ got_start_event => 0, sub {
      $_[HEAP]{wheel} = POE::Wheel::FollowTail->new(
        InputEvent   => 'input_event',
        ResetEvent   => 'reset_event',
        IdleEvent    => 'idle_event',
        Filename     => LOG,
        PollInterval => 1,
      );
    }
  ],
  [ got_idle_event  => 0,   sub { append_to_log("a") } ],
  [ did_log_append  => "a", sub { undef } ],
  [ got_reset_event => 0,   sub { undef } ], # Initial open is a reset.
  [ got_input_event => "a", sub { undef} ],
  [ got_idle_event  => 0,   sub {
      append_to_log("b");
      roll_log();
      append_to_log("c");
    }
  ],
  [ did_log_append  => "b", sub { undef } ],
  [ did_log_roll    => 0,   sub { undef } ],
  [ did_log_append  => "c", sub { undef } ],
  [ got_input_event => "b", sub { undef } ],
  [ got_reset_event => 0,   sub { undef } ],
  [ got_input_event => "c", sub { append_to_log("d") } ],
  [ did_log_append  => "d", sub { undef } ],
  [ got_input_event => "d", sub { delete $_[HEAP]{wheel} } ],
  [ got_stop_event  => 0,   sub {
      # Clean up test log files, if we can.
      unlink LOG     or die "unlink failed: $!";
      unlink OLD_LOG or die "unlink failed: $!";
    }
  ],
);

plan tests => scalar @expected_results;

POE::Session->create(
  inline_states => {
    _start      => \&handle_start_event,
    _stop       => \&handle_stop_event,
    input_event => \&handle_input_event,
    reset_event => \&handle_reset_event,
    idle_event  => \&handle_idle_event,
  }
);

POE::Kernel->run();
exit;

#
# subs
#

sub test_event {
  my ($event, $parameter) = @_;
  my $expected_result = shift @expected_results;
  unless (defined $expected_result) {
    fail("Got an unexpected result ($event, $parameter). Time to bye.");
    exit;
  }

  my $next_action = pop @$expected_result;

  note "Testing (@$expected_result)";

  is_deeply( [ $event, $parameter ], $expected_result );

  return $next_action;
}

sub handle_reset_event {
  my $next_action = test_event("got_reset_event", 0);
  goto $next_action;
}

sub handle_idle_event {
  my $next_action = test_event("got_idle_event", 0);
  goto $next_action;
}

sub handle_input_event {
  my $next_action = test_event("got_input_event", $_[ARG0]);
  goto $next_action;
}

sub handle_start_event {
  my $next_action = test_event("got_start_event", 0);
  goto $next_action;
}

sub handle_stop_event {
  my $next_action = test_event("got_stop_event", 0);
  goto $next_action;
}

sub roll_log {
  test_event did_log_roll => 0;
  rename LOG, OLD_LOG or die "rename failed: $!";
  return;
}

sub append_to_log {
  my ($line) = @_;

  test_event did_log_append => $line;

  open my $fh, '>>', LOG      or die "open failed: $!";
  print {$fh} "$line\n";
  close $fh                   or die "close failed: $!";

  return;
}


1;
