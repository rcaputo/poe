#!/usr/bin/perl

use strict;
use vars qw($NUM_OF_EVENTS $USE_EVENT $USE_IO_POLL);

use Time::HiRes qw(gettimeofday tv_interval);

sub die_usage { 
    my $usage = "\n";
    if(my $msg = shift) {
        $usage .= "ERROR: $msg\n\n";
    }
    $usage .= <<EOU;
Usage: $0 < --events=NUM > < --use-event > < --use-io-poll >
Options:  
    --help         :  this help text
    --events=NUM   :  the number of events to run. defaults to 10000
    --use-event    :  use Event.pm's internal event loop
    --use-io-poll  :  use IO::Poll.pm's internal event loop

    if --use-event or --use-io-poll are not chosen, POE's native event loop
    will be used.
EOU
    my_die($usage); 
}

sub my_die ($) {
    print STDERR $_[0]."\n";
    exit 1;
}

sub late_use ($) {
    my $module = shift;
    eval "use $module;";
    my_die($@) if ($@);
}

BEGIN { 
    use Getopt::Long;
    $USE_EVENT = 0;
    $USE_IO_POLL = 0;
    my $help = 0;

    $NUM_OF_EVENTS = 10000;
    
    GetOptions( 'events=i' => \$NUM_OF_EVENTS,
                'use-event+' => \$USE_EVENT,
                'use-io-poll+' => \$USE_IO_POLL,
                'help+' => \$help,
                );
    die_usage() if $help;
    die_usage('Both use-event and use-io-poll are selected. Only one loop type may be chosen.') if($USE_EVENT + $USE_IO_POLL > 1);

    if($USE_EVENT) {
        late_use('Event');
    } elsif ($USE_IO_POLL) {
        late_use('IO::Poll');
    }

    late_use('POE');
}


my($tr_start, $tr_stop);
POE::Session->create(
    inline_states => {
        _start => sub { $tr_start = [gettimeofday]; $_[KERNEL]->yield('iterate', 0) },
        _stop => sub { $tr_stop = [gettimeofday] },

        iterate => sub { $_[KERNEL]->yield('iterate', ++$_[ARG0]) unless $_[ARG0] > $NUM_OF_EVENTS; }
    }
);

$POE::Kernel::poe_kernel->run();

my $elapsed = tv_interval($tr_start, $tr_stop);
my $event_avg = int($NUM_OF_EVENTS/$elapsed);
print "Events per second: $event_avg\n";

