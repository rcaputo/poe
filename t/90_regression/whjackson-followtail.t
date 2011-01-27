#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;
use warnings;

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
  plan tests => 10;
}

my @expected = (
  [ append_to_log => "a"  ],
  [ reset_event   => 0    ],
  [ got_log       => "a"  ],
  [ append_to_log => "b"  ],
  [ roll_log      => 0    ],
  [ append_to_log => "c"  ],
  [ got_log       => "b"  ],
  [ reset_event   => 0    ],
  [ got_log       => "c"  ],
  [ done          => 0    ],
);

POE::Session->create(
  inline_states => {
    _start           => \&_start_handler,
    append_to_log    => \&append_to_log,
    roll_log         => \&roll_log,
    done             => \&done,

    # FollowTail events
    input_event      => \&input_handler,
    reset_event      => \&reset_handler,
  }
);

POE::Kernel->run();
exit;

#
# subs
#

sub logger {
  my $log_info = [ @_ ];
  my $next = shift @expected;
  is_deeply( $log_info, $next );
  return;
}

sub _start_handler {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{wheel} = POE::Wheel::FollowTail->new(
    InputEvent   => 'input_event',
    ResetEvent   => 'reset_event',
    Filename     => LOG,
    PollInterval => 4,
  );

  #
  # what                               when  arg
  #----------------------------------------------
  # poll log file                      1
  $kernel->delay_add('append_to_log',  2,  'a');
  # necessary no-op gap                3
  # poll log file                      4
  $kernel->delay_add('append_to_log',  5,  'b');
  $kernel->delay_add('roll_log',       6      );
  $kernel->delay_add('append_to_log',  7,  'c');
  # poll log file                      8
  $kernel->delay_add('done',           10     );

  return;
}

sub input_handler {
  my ($kernel, $line) = @_[KERNEL, ARG0];
  logger got_log => $line;
  return;
}

sub reset_handler {
  logger reset_event => 0;
  return;
}

sub roll_log {
  logger roll_log => 0;
  rename LOG, OLD_LOG or die "rename failed: $!";
  return;
}

sub append_to_log {
  my $line = $_[ARG0];
  logger append_to_log => $line;

  open my $fh, '>>', LOG      or die "open failed: $!";
  print {$fh} "$line\n";
  close $fh                   or die "close failed: $!";

  return;
}

sub done {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  logger done => 0;

  # cleanup the test log files
  unlink LOG     or die "unlink failed: $!";
  unlink OLD_LOG or die "unlink failed: $!";

  # delete the wheel so the POE session can end
  delete $heap->{wheel};

  return;
}

1;
