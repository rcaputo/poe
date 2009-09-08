#!/usr/bin/perl
# vim: filetype=perl ts=2 sw=2 expandtab

use warnings;
use strict;

my $USE_SIGCHLD = 0;

sub USE_SIGCHLD () { $USE_SIGCHLD }

use POE;
use POE::Wheel::Run;
use Test::More;

sub DEBUG () { 0 }

my $N = 3;
my $S = 1;
diag "This test can take up to ", $S*2, " seconds";

plan ( tests => 6*$N + 3 );


diag( "Without USE_SIGCHLD" );

Work->spawn( $N, $S );
$poe_kernel->run;

$USE_SIGCHLD = 1;
diag("With USE_SIGCHLD");

Work->spawn( $N, $S );
$poe_kernel->run;

pass( "Sane exit" );

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
        foreach my $n (1 .. $N) {
          DEBUG and diag "$$: Launch child $n";
          my $w = POE::Wheel::Run->new(
            Program => \&spawn_child,
            ProgramArgs => [ $sleep ],
            StdoutEvent => 'chld_stdout',
            StderrEvent => 'chld_stdin',
            CloseEvent  => 'chld_close'
          );
          $heap->{PID2W}{$w->PID} = {ID => $w->ID, N => $n, closing=>0};
          $heap->{W}{$w->ID} = $w;
        }

        $heap->{TID} = $poe_kernel->delay_set(timeout => $sleep*2);
      },

      chld_stdout => sub {
        my ($heap, $line, $wid) = @_[HEAP, ARG0, ARG1];
        my $W = $heap->{W}{$wid};
        die "Unknown wheel $wid" unless $W;
        is( $line, 'DONE', "stdout from $wid" );
        if( $line eq 'DONE' ) {
          my $data = $heap->{PID2W}{ $W->PID };
          $data->{closing} = 1;
        }
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
        DEBUG and diag "$$: saying goodbye";
        foreach my $wheel (values %{$_[HEAP]{W}}) {
          $wheel->put("die\n");
        }
        DEBUG and diag "$$: said my goodbyes";
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
        close_on( 'CHLD', $heap, $data->{ID} );
      },
      chld_close => sub {
        my ($heap, $wid) = @_[HEAP, ARG0];
        DEBUG and diag "$$: close $wid";
        close_on( 'close', $heap, $wid );
      }

    }
  );
}

sub close_on {
  my( $why, $heap, $wid ) = @_;

  my $W = $heap->{W}{$wid};
  die "Unknown wheel $wid" unless $W;

  my $data = $heap->{PID2W}{ $W->PID };

  $data->{$why}++;
  return unless $data->{CHLD} and $data->{close};

  is( $data->{closing}, 1, "Expecting to close" );

  delete $heap->{PID2W}{$W->PID};
  delete $heap->{W}{$data->{ID}};
  pass("Child $data->{ID} exit detected.");

  unless (keys %{$heap->{W}}) {
    pass "all children have exited";
    $poe_kernel->alarm_remove(delete $heap->{TID});
  }
}


sub spawn_child {
  my( $sleep ) = @_;
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
      }
    }
  );
  POE::Kernel->run;
}
