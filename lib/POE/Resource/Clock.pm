# Manage a platonic, monotonic clock to keep the event queue ordered

package POE::Resource::Clock;

use vars qw($VERSION);
$VERSION = '1.354'; # NOTE - Should be #.### (three decimal places)

use strict;

use Config;
use POSIX;
use POE::Pipe::OneWay;
use File::Spec;

sub DEBUG () { 0 }

sub CLK_TIMEOUT () { 0 }
sub CLK_SKEW    () { 1 }

sub CLK_EN_READ () { "rt-lock-read" }

#########################################
sub do_X 
{
    my( $X, $default ) = @_;
    my $m = $X;
    return POE::Kernel->can( $m )->() if POE::Kernel->can( $m );
    my $k = "POE_$X";
    return $ENV{$k} if exists $ENV{$k};
    return $default if defined $default;
    return 1;
}

#########################################
sub exact_epoch
{
    my( $monoclock ) = @_;
           
    # Try to get the exact difference between the monotonic clock's epoch
    # and the system clock's epoch.  We do this by comparing the 2 for 0.25 second
    # or 10 samples.  To compensate for delays between calling time and get_time,
    # we run in both order.  Even so, I still see up to 10 mS divergence in my dev VM
    # between invocations
    my $N=0;
    my $total = 0;
    my $end = $monoclock->get_time() + 0.25;
    while( $end > $monoclock->get_time() or $N < 20) {
        my $hr = Time::HiRes::time();
        my $mono = $monoclock->get_time;
        $total += $hr - $mono;
        $N++;
        $mono = $monoclock->get_time;
        $hr = Time::HiRes::time();
        $total += $hr - $mono;
        $N++;
    }
    DEBUG and POE::Kernel::_warn( "<ck> RT clock samples=$N" );
    return $total/$N;
}

#########################################
sub get_epoch
{
    my( $monoclock, $wallclock ) = @_;
    return $wallclock->get_time - $monoclock->get_time;
}


#########################################
sub build_pipe
{
    my( $read, $write ) = POE::Pipe::OneWay->new();
    die "Unable to build pipe: $!" unless defined $read;
    return ( $read, $write );
}

#########################################
our $FORMAT = 'iF';
our $LENGTH = length pack $FORMAT, 0, 0;
sub pipe_write
{
    my( $write, $op, $skew ) = @_;
    DEBUG and POE::Kernel::_warn( "<ck> write op=$op" );
    my $buffer = pack $FORMAT, $op, $skew;
    syswrite( $write, $buffer, $LENGTH );
}

#########################################
sub pipe_read
{
    my( $read ) = @_;
    my $buffer;
    sysread( $read, $buffer, $LENGTH );
    return unless length $buffer;
    return unpack $FORMAT, $buffer;
}

#########################################
our( $SIGACT, $SIGSET );
sub build_sig
{
    my( $write ) = @_;
    my $handler = sub { 
            DEBUG and POE::Kernel::_warn( "<ck> timeout" );
            pipe_write( $write, CLK_TIMEOUT, 0 ); 
        };
    my $default = eval { sig_number( 'RTMIN' ) } ||
                  eval { sig_number( 'RTALRM' ) } ||
                  SIGALRM;

    my $signal = do_X( 'CLOCK_SIGNAL', $default ) || $default;
    $SIGSET = POSIX::SigSet->new( $signal );
    $SIGACT = POSIX::SigAction->new( $handler, $SIGSET, 0 );
    $SIGACT->safe(1);
    POSIX::sigaction( $signal, $SIGACT );
    return $signal;
}

#########################################
sub build_timer
{
    my( $signal ) = @_;
    return POSIX::RT::Timer->new( 
                    value => 0,
                    interval => 0,
                    clock => 'monotonic',
                    signal => $signal
                );
}

#########################################
sub rt_setup
{
    my( $read, $kernel ) = @_;
    $kernel->loop_pause_time_watcher();
    DEBUG and POE::Kernel::_warn( "<ck> Setup RT pipe" );
    # Add to the select list
    $kernel->_data_handle_condition( $read );
    $kernel->loop_watch_filehandle( $read, POE::Kernel::MODE_RD() );
}

our $EPSILON = 0.0001;
sub rt_resume
{
    my( $what, $timer, $kernel, $pri ) = @_;
    DEBUG and POE::Kernel::_warn( "<ck> $what pri=$pri" );
    $kernel->loop_pause_time_watcher;
    if( $pri <= monotime() ) {
        $timer->set_timeout( $EPSILON );
    }
    else {
        $timer->set_timeout( $pri, 0, 1 );
    }
}

sub rt_pause
{
    my( $timer, $kernel ) = @_;
    DEBUG and POE::Kernel::_warn( "<ck> Pause" );
    $timer->set_timeout( 60 );
    $kernel->loop_pause_time_watcher
}

#########################################
sub rt_read_pipe
{
    my( $kernel, $read ) = @_;
    my $dispatch_once;
    while( 1 ) {
        my( $op, $skew ) = pipe_read( $read );
        return unless defined $op;
        DEBUG and POE::Kernel::_warn( "<ck> Read pipe op=$op" );
        if( $op == CLK_TIMEOUT ) {
            next unless $dispatch_once;
            $kernel->_data_ev_dispatch_due();
            $dispatch_once = 1;
        }
        elsif( $op == CLK_SKEW ) {
            rt_skew( $kernel );
            $dispatch_once = 0;
        }
        elsif( DEBUG ) {
            POE::Kernel::_warn( "<ck> Unknown op=$op" );
        }
    }
}

#########################################
sub rt_ready
{
    my( $read, $frd, $kernel, $fileno ) = @_;
    return 0 unless $frd == $fileno;
    rt_read_pipe( $kernel, $read );
    return 1;
}


#########################################
sub loop_pause
{
    my( $kernel ) = @_;
    $kernel->loop_pause_time_watcher;
}

sub loop_reset
{
    my( $kernel, $pri ) = @_;
    $kernel->loop_reset_time_watcher( mono2wall( $pri ) );
}

sub loop_resume
{
    my( $kernel, $pri ) = @_;
    $kernel->loop_resume_time_watcher( mono2wall( $pri ) );
}

#########################################
my %SIGnames;
sub sig_number
{
    my( $name ) = @_;
    return $name if $name =~ /^\d+$/;
    my $X = 0;
    $X = $1 if $name =~ s/\+(\d+)$//;
    unless( %SIGnames ) {
        # this code is lifted from Config pod
        die "Config is missing either sig_name or sig_num;  You must use a numeric signal"
            unless $Config{sig_name} and $Config{sig_num};
        my @names = split ' ', $Config{sig_name};
        @SIGnames{@names} = split ' ', $Config{sig_num};
    }
    return $SIGnames{ $name }+$X;
}

#########################################
BEGIN {
    my $done;
    my $have_clock;
    if( do_X( 'USE_POSIXRT' ) ) {
        eval {
            require File::Spec->catfile( qw( POSIX RT Clock.pm ) );
            require File::Spec->catfile( qw( POSIX RT Timer.pm ) );
            my $monoclock = POSIX::RT::Clock->new( 'monotonic' );
            my $wallclock = POSIX::RT::Clock->new( 'realtime' );
            *monotime = sub { return $monoclock->get_time; };
            *walltime = sub { return $wallclock->get_time; };
            *sleep = sub { $monoclock->sleep_deeply(@_) };
            if( do_X( 'USE_STATIC_EPOCH' ) ) {
                # This is where we cheat:  without a static epoch the tests fail
                # because they expect alarm(), alarm_set() to arrive in order
                # Calling get_epoch() each time would preclude this
                my $epoch = 0;
                if( do_X( 'USE_EXACT_EPOCH', 0 ) ) {
                    $epoch = exact_epoch( $monoclock, $wallclock );
                }
                else {
                    $epoch = get_epoch( $monoclock, $wallclock );
                }
                DEBUG and warn( "<ck> epoch=$epoch" );
                *wall2mono = sub { $_[0] - $epoch };
                *mono2wall = sub { $_[0] + $epoch };
            }
            else {
                *wall2mono = sub { $_[0] - get_epoch($monoclock, $wallclock) };
                *mono2wall = sub { $_[0] + get_epoch($monoclock, $wallclock) };

                my( $rd, $wr ) = build_pipe();
                my $signal = build_sig( $wr );
                my $timer = build_timer( $signal );
                $EPSILON = $monoclock->get_resolution();
                DEBUG and warn( "<ck> epsilon=$EPSILON" );
                *clock_pause = sub { rt_pause( $timer, @_ ); };
                *clock_reset = sub { rt_resume( Reset => $timer, @_ ); };
                *clock_resume = sub { rt_resume( Resume => $timer, @_ ); };
                *clock_setup = sub { rt_setup( $rd, @_ ) };
                my $frd = fileno( $rd );
                *clock_read = sub { rt_ready( $rd, $frd, @_ ) };
                $have_clock = 1;
            }
            $done = 1;
        };
        if( DEBUG ) {
            warn( "<ck> POSIX::RT::Clock not installed: $@" ) if $@;
            warn( "<ck> using POSIX::RT::Clock" ) if $done;
        }
    }
    if( !$done and do_X( 'USE_HIRES' ) ) {
        eval {
            require File::Spec->catfile( qw( Time HiRes.pm ) );
            *monotime = \&Time::HiRes::time;
            *walltime = \&Time::HiRes::time;
            *sleep = \&Time::HiRes::sleep;
            *wall2mono = sub { return $_[0] };
            *mono2wall = sub { return $_[0] };
            $done = 1;
        };
        if( DEBUG ) {
            warn( "<ck> Time::HiRes not installed: $@" )if $@;
            warn( "<ck> using Time::HiRes" ) if $done;
        }
    }
    unless( $done ) {
        # \&CORE::time fails :-(
        *monotime = sub { CORE::time };
        *walltime = sub { CORE::time };
        *sleep = sub { CORE::sleep(@_) };
        *wall2mono = sub { return $_[0] };
        *mono2wall = sub { return $_[0] };
        warn( "<ck> using CORE::time" )if DEBUG;
    }

    unless( $have_clock ) {
        *clock_pause = \&loop_pause;
        *clock_reset = \&loop_reset;
        *clock_resume = \&loop_resume;
        *clock_setup = sub { 0 };
        *clock_read = sub { 0 };
    }

    # *time = sub { Carp::confess( "This should be monotime" ) };
    *time = \&walltime;
}

require Exporter;
our @EXPORT_OK = qw( monotime sleep walltime wall2mono mono2wall time );
our @ISA = qw( Exporter );

1;

__END__

=head1 NAME

POE::Resource::Clock - internal clock used for ordering the queue

=head1 SYNOPSIS

    sub POE::Kernel::USE_POSIXRT { 0 }
    use POE;

=head1 DESCRIPTION

POE::Resource::Clock is a helper module for POE::Kernel.  It provides the
features to keep an internal monotonic clock and a wall clock.  It also
converts between this monotonic clock and the wall clock.

The monotonic clock is used to keep an ordered queue of events.  The wall
clock is used to comunicate the time with user code
(L<POE::Kernel/alarm_set>, L<POE::Kernel/alarm_remove>).

There are 3 possible clock sources in order of preference:
L<POSIX::RT::Clock>, L<Time::HiRes> and L<perlfunc/time>.  Only
C<POSIX::RT::Clock> has a seperate monotonic and wall clock; the other two use the
same source for both clocks.

Clock selection and behaviour is controled with the following:

=head2 USE_POSIXRT

    export POE_USE_POSIXRT=0
        or
    sub POE::Kernel::USE_POSIXRT { 0 }

Uses the C<monotonic> clock source for queue priority and the C<realtime>
clock source for wall clock.  Not used if POSIX::RT::Clock is not installed
or your system does not have a C<monotonic> clock.

Defaults to true.  If you want the old POE behaviour, set this to 0.

=head2 USE_STATIC_EPOCH

    export POE_USE_STATIC_EPOCH=0
        or
    sub POE::Kernel::USE_STATIC_EPOCH { 0 }

The epoch of the POSIX::RT::Clock monotonic is different from that of the
realtime clock.  For instance on Linux 2.6.18, the monotonic clock is the
number of seconds since system boot.  This epoch is used to convert from
walltime into monotonic time for L<POE::Kernel/alarm>,
L<POE::Kernel/alarm_add> and L<POE::Kernel/alarm_set>. If
C<USE_STATIC_EPOCH> is true (the default), then the epoch is calculated at
load time.  If false, the epoch is calculated each time it is needed.

Defaults to true.  Only relevant for if using POSIX::RT::Clock. Long-running
POE servers should have this set to false so that system clock skew does
mess up the queue.

It is important to point out that without a static epoch, the ordering of
the following two alarms is undefined.

    $poe_kernel->alarm_set( a1 => $time );
    $poe_kernel->alarm_set( a2 => $time );

=head2 USE_EXACT_EPOCH

    export POE_USE_EXACT_EPOCH=1
        or
    sub POE::Kernel::USE_EACT_EPOCH { 1 }

There currently no way to exactly get the monotonic clock's epoch.  Instead
the difference between the current monotonic clock value to the realtime
clock's value is used.  This is obviously inexact because there is a slight
delay between the 2 system calls.  Setting USE_EXACT_EPOCH to true will
calculate an average of this difference over 250 ms or at least 20 samples. 
What's more, the system calls are done in both orders (monotonic then
realtime, realtime then monotonic) to try and get a more eact value.

Defaults to false.  Only relevant if L</USE_STATIC_EPOCH> is true.


=head2 USE_HIRES

    export POE_USE_HIRES=0
        or
    sub POE::Kernel::USE_HIRES { 0 }

Use L<Time::HiRes> as both monotonic and wall clock source.  This was POE's
previous default clock.

Defaults to true.  Only relevant if L</USE_POSIXRT> is false.  Set this to false to use
L<perlfunc/time>.


=head1 SEE ALSO

See L<POE::Resource> for general discussion about resources and the
classes that manage them.

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
