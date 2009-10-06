#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use warnings;
use strict;

sub POE::Kernel::CATCH_EXCEPTIONS () { 0 }
sub POE::Kernel::USE_SIGCHLD      () { 0 }
sub POE::Kernel::USE_SIGNAL_PIPE  () { 0 }
sub POE::Kernel::ASSERT_DEFAULT   () { 1 }
sub POE::Kernel::TRACE_DEFAULT    () { 0 }

use POE;
use POE::Wheel::Run;
use Test::More;

sub DEBUG () { 0 }

my $child_process_limit = 3;
my $seconds_children_sleep = 1;

# Each child process:
#   child sent done
#   child flushed
#   child exited
# Each spawn
#   All children exited
# Whole program
#   Sane exit

my $test_count = 3 * $child_process_limit + 1 + 1;
plan tests => $test_count;

SKIP: {
  skip("$^O handles fork/call poorly", $test_count) if (
    $^O eq "MSWin32" and not $ENV{POE_DANTIC}
  );

  diag "This test can take up to ", $seconds_children_sleep*10, " seconds";

  Work->spawn( $child_process_limit, $seconds_children_sleep );
  $poe_kernel->run;

  pass( "Sane exit" );
}

############################################################################
package Work;

use strict;
use warnings;
use POE;
use Test::More;

BEGIN {
    *DEBUG = \&::DEBUG;
}

sub spawn {
  my( $package, $count, $sleep ) = @_;
  POE::Session->create(
    inline_states => {
      _start => sub {
        my ($heap) = @_[HEAP, ARG0..$#_];
        $poe_kernel->sig(CHLD => 'sig_CHLD');
        foreach my $n (1 .. $count) {
          DEBUG and diag "$$: Launch child $n";
          my $w = POE::Wheel::Run->new(
            Program => \&spawn_child,
            ProgramArgs => [ $sleep ],
            StdoutEvent => 'chld_stdout',
            StderrEvent => 'chld_stderr',
            CloseEvent  => 'chld_close'
          );
          $heap->{PID2W}{$w->PID} = {ID => $w->ID, N => $n, flushed=>0};
          $heap->{W}{$w->ID} = $w;
        }

        $heap->{TID} = $poe_kernel->delay_set(timeout => $sleep*10);
      },

      chld_stdout => sub {
        my ($heap, $line, $wid) = @_[HEAP, ARG0, ARG1];
        my $wheel = $heap->{W}{$wid};
        die "Unknown wheel $wid" unless $wheel;
        $line =~ s/\s+//g;
        is( $line, 'DONE', "stdout from $wid" );
        if( $line eq 'DONE' ) {
          my $data = $heap->{PID2W}{ $wheel->PID };
          $data->{flushed} = 1;
        }
      },

      chld_stderr => sub {
        my ($heap, $line, $wid) = @_[HEAP, ARG0, ARG1];
        my $wheel = $heap->{W}{$wid};
        die "Unknown wheel $wid" unless $wheel;
        if (DEBUG) {
          diag "CHILD " . $wheel->PID . " STDERR: $line";
        }
        else {
          fail "stderr from $wid: $line";
        }
      },

      say_goodbye => sub {
        DEBUG and diag "$$: saying goodbye";
        foreach my $wheel (values %{$_[HEAP]{W}}) {
          $wheel->put("die\n");
        }
        DEBUG and diag "$$: said my goodbyes";
      },

      timeout => sub {
        fail "Timed out waiting for children to exit";
        $poe_kernel->stop();
      },

      sig_CHLD => sub {
        my ($heap, $signal, $pid) = @_[HEAP, ARG0, ARG1];
        DEBUG and diag "$$: CHLD $pid";
        my $data = $heap->{PID2W}{$pid};
        die "Unknown wheel PID=$pid" unless defined $data;
        close_on( 'CHLD', $heap, $data->{ID} );
      },

      chld_close => sub {
        my ($heap, $wid) = @_[HEAP, ARG0];
        DEBUG and diag "$$: close $wid";
        close_on( 'close', $heap, $wid );
      },

      _stop => sub { }, # Pacify ASSERT_DEFAULT.
    }
  );
}

sub close_on {
  my( $why, $heap, $wid ) = @_;

  my $wheel = $heap->{W}{$wid};
  die "Unknown wheel $wid" unless $wheel;

  my $data = $heap->{PID2W}{ $wheel->PID };

  $data->{$why}++;
  return unless $data->{CHLD} and $data->{close};

  is( $data->{flushed}, 1, "expected child flush" );

  delete $heap->{PID2W}{$wheel->PID};
  delete $heap->{W}{$data->{ID}};
  pass("Child $data->{ID} exit detected.");

  unless (keys %{$heap->{W}}) {
    pass "all children have exited";
    $poe_kernel->alarm_remove(delete $heap->{TID});
  }
}

sub spawn_child {
  my( $sleep ) = @_;
  #close STDERR;
  #open STDERR, ">", "child-err.$$";

  DEBUG and diag "$$: child sleep=$sleep";

  POE::Kernel->stop;

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->delay( done => $sleep );
      },
      _stop => sub {
        DEBUG and diag "$$: child _stop";
      },
      done => sub {
        DEBUG and diag "$$: child done";
        print "DONE\n";
      },
    }
  );
  POE::Kernel->run;
}
