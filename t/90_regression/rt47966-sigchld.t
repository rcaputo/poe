#!/usr/bin/perl
# vim: filetype=perl tw=2 sw=2 expandtab

use warnings;
use strict;

use POE;
use POE::Wheel::Run;
use Test::More;

sub DEBUG () { 0 }

unless ($ENV{TEST_MAINTAINER}) {
  plan skip_all => 'Set TEST_MAINTAINER to run this test';
  exit 0;
}

my $N = 60;
diag "This test will over ", int($N / 3), " seconds";
plan tests => $N + 2;

POE::Session->create(
  inline_states => {
    _start => sub {
      my ($heap, $count) = @_[HEAP, ARG0];
      $poe_kernel->sig(CHLD => 'sig_CHLD');
      my $max;
      foreach my $n (1 .. $N) {
        my $time = int rand($N / 3);
        DEBUG and diag "$$: Launch child $n (time=$time)";
        my $w = POE::Wheel::Run->new(
          Program => sub {
            DEBUG and warn "$$: $n sleep $time";
            sleep $time;
            exit 0;
          },
          StdoutEvent => 'chld_stdout',
          StderrEvent => 'chld_stdin',
        );
        $max = $time if not $max or $max < $time;
        $heap->{PID2W}{$w->PID} = {ID => $w->ID, N => $n};
        $heap->{W}{$w->ID} = $w;
      }
      $heap->{TID} = $poe_kernel->delay_set(timeout => $max + 2);

    },

    chld_stdout => sub {
      my ($heap, $line, $wid) = @_[HEAP, ARG0, ARG1];
      my $W = $heap->{W}{$wid};
      die "Unknown wheel $wid" unless $W;
      fail "stdout from $wid: $line";
    },

    chld_stderr => sub {
      my ($heap, $line, $wid) = @_[HEAP, ARG0, ARG1];
      my $W = $heap->{W}{$wid};
      die "Unknown wheel $wid" unless $W;
      if (DEBUG) {
        diag $line;
      }
      else {
        fail "stderr from $wid: $line";
      }
    },

    timeout => sub {
      fail "Timed out waiting for children to exit";
      $poe_kernel->stop;
    },

    sig_CHLD => sub {
      my ($heap, $signal, $pid) = @_[HEAP, ARG0, ARG1];
      DEBUG and diag "$$: CHLD $pid";
      my $data = $heap->{PID2W}{$pid};
      die "Unknown wheel PID=$pid" unless defined $data;
      my $W = $heap->{W}{$data->{ID}};
      die "Unknown wheel $data->{ID}" unless $W;
      delete $heap->{PID2W}{$pid};
      delete $heap->{W}{$data->{ID}};
      pass("Child $data->{ID} exit detected.");

      unless (keys %{$heap->{W}}) {
        pass "all children have exited";
        $poe_kernel->alarm_remove(delete $heap->{TID});
      }
    }
  }
);

$poe_kernel->run;

pass("Sane exit");
