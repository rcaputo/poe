#!/usr/bin/perl

use strict;
use warnings;

use POE;

use Test::More ( tests => 4 );

pass( "BEGIN" );
POE::Session->create( inline_states => {
        _start => sub {
                my $heap = $_[HEAP];
                $heap->{started} = time;
                $heap->{alarm} = $poe_kernel->alarm_set( 'the_alarm' => time+10 );
                $heap->{delay} = $poe_kernel->delay_set( 'the_delay' => 10 );
                $poe_kernel->yield( 'adjust_them' );
            },
        adjust_them => sub {
                my $heap = $_[HEAP];
                $poe_kernel->delay_adjust( $heap->{delay}, 3 );  # 3 seconds from now
                $poe_kernel->alarm_adjust( $heap->{alarm}, -7 ); # 10-7 seconds
                diag( "Waiting 3 seconds (or 10)" );
            },

        the_delay => sub {
                my $heap = $_[HEAP];
                my $took = time - $heap->{started};
                ok( $took < 5, "Short delay ($took)" );
            },
        the_alarm => sub {
                my $heap = $_[HEAP];
                my $took = time - $heap->{started};
                ok( $took < 5, "Short alarm ($took)" );
            },
    } );
       
$poe_kernel->run;

pass( "END" );