#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

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
diag "This test can take up to about ", int($N / 3), " seconds";
plan tests => $N + 2;

POE::Session->create(
  inline_states => {
    _start => sub {
      my ($heap, $count) = @_[HEAP, ARG0];
      $poe_kernel->sig(CHLD => 'sig_CHLD');
      foreach my $n (1 .. $N) {
        DEBUG and diag "$$: Launch child $n";
        my $w = POE::Wheel::Run->new(
          Program => sub {
            DEBUG and warn "$$: waiting for input";
            <STDIN>;
            exit 0;
          },
          StdoutEvent => 'chld_stdout',
          StderrEvent => 'chld_stdin',
        );
        $heap->{PID2W}{$w->PID} = {ID => $w->ID, N => $n};
        $heap->{W}{$w->ID} = $w;
      }

      DEBUG and warn "$$: waiting 1 sec for things to settle";
      $_[KERNEL]->delay(say_goodbye => 1);
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

    say_goodbye => sub {
      DEBUG and warn "$$: saying goodbye";
      foreach my $wheel (values %{$_[HEAP]{W}}) {
        $wheel->put("die\n");
      }
      $_[HEAP]{TID} = $poe_kernel->delay_set(timeout => $N);
      DEBUG and warn "$$: said my goodbyes";
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
