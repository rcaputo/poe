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
use POE::Test::Sequence;

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

my $sequence = POE::Test::Sequence->new(
  sequence => [
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
    [ did_log_append  => "a", undef ],
    [ got_reset_event => 0,   undef ], # Initial open is a reset.
    [ got_input_event => "a", undef ],
    [ got_idle_event  => 0,   sub {
        append_to_log("b");
        roll_log();
        append_to_log("c");
      }
    ],
    [ did_log_append  => "b", undef ],
    [ did_log_roll    => 0,   undef ],
    [ did_log_append  => "c", undef ],
    [ got_input_event => "b", undef ],
    [ got_reset_event => 0,   undef ],
    [ got_input_event => "c", sub { append_to_log("d") } ],
    [ did_log_append  => "d", undef ],
    [ got_input_event => "d", sub { delete $_[HEAP]{wheel} } ],
    [ got_stop_event  => 0,   sub {
        # Clean up test log files, if we can.
        unlink LOG     or die "unlink failed: $!";
        unlink OLD_LOG or die "unlink failed: $!";
      }
    ],
  ],
);

plan tests => $sequence->test_count();

POE::Session->create(
  inline_states => {
    _start      => sub { goto $sequence->next("got_start_event", 0) },
    _stop       => sub { goto $sequence->next("got_stop_event",  0) },
    input_event => sub { goto $sequence->next("got_input_event", $_[ARG0]) },
    reset_event => sub { goto $sequence->next("got_reset_event", 0) },
    idle_event  => sub { goto $sequence->next("got_idle_event",  0) },
  }
);

POE::Kernel->run();
exit;

# Helpers.

sub roll_log {
  $sequence->next("did_log_roll", 0);
  rename LOG, OLD_LOG or die "rename failed: $!";
  return;
}

sub append_to_log {
  my ($line) = @_;

  $sequence->next("did_log_append", $line);

  open my $fh, '>>', LOG      or die "open failed: $!";
  print {$fh} "$line\n";
  close $fh                   or die "close failed: $!";

  return;
}

1;
