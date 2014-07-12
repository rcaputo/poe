#!/usr/bin/perl
# vim: ts=2 sw=2 expandtab
#
use strict;
use warnings;

use Time::HiRes qw(time);
use POE;

use Test::More;

use POE::Test::Sequence;

my $sequence = POE::Test::Sequence->new(
  sequence => [
    [
      '_start', 0, sub {
        my $heap = $_[HEAP];
        my $now = $heap->{started} = time();
        $heap->{alarm}   = POE::Kernel->alarm_set( 'the_alarm' => $now+10 );
        $heap->{delay}   = POE::Kernel->delay_set( 'the_delay' => 10 );
        POE::Kernel->yield( 'adjust_them' );
      },
    ],
    [
      'adjust_them', 0, sub {
        my $heap = $_[HEAP];
        POE::Kernel->delay_adjust( $heap->{delay}, 1 );  # 1 seconds from now
        POE::Kernel->alarm_adjust( $heap->{alarm}, -9 ); # 10-9 seconds
        note( "Waiting 1 second (or 10)" );
      },
    ],
    [
      'the_alarm', 0, sub {
        my $heap = $_[HEAP];
        my $took = time() - $heap->{started};
        ok( $took < 2, "Short alarm ($took)" );
      },
    ],
    [
      'the_delay', 0, sub {
        my $heap = $_[HEAP];
        my $took = time() - $heap->{started};
        ok( $took < 2, "Short delay ($took)" );
      },
    ],
    [ '_stop', 0, undef ],
  ],
);

# Two additional tests for short delays.
plan tests => $sequence->test_count() + 2;

$sequence->create_generic_session();
POE::Kernel->run();
exit;
