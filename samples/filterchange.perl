#!/usr/bin/perl -w
# $Id$

# This program tests the new filter-changing capabilities of
# Wheel::ReadWrite

use strict;
use lib '..';

##############################################################################
# This is the caller.
# It causes the other side to switch filters insessantly

package Cause;
use strict;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Stream);
use Data::Dumper;
use Storable qw(freeze thaw);

###############################################
# Create our top session
sub create
{
    my($port)=@_;
    POE::Session->new
    (
        _start=>\&c_start,
        _stop=>\&c_stop,
        error=>\&c_error,
        connected=>\&c_connected,
        [$port],
    );
}

###############################################
# Start the top session
sub c_start
{
    my($heap, $port)=@_[HEAP, ARG0];
    $heap->{wheel} = new POE::Wheel::SocketFactory
    ( RemotePort     => $port,
      RemoteAddress  => '127.0.0.1',
      SuccessState   => 'connected',    # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );
}

###############################################
# Simple notice when we stop
sub c_stop
{
    print "Cause  [$$] stoped\n";
}
###############################################
# Errors at connect time
sub c_error
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    print "Cause  [$$] encountered $operation error $errnum: $errstr\n";
    delete $heap->{wheel};
}

###############################################
# Connected the Effect.
# Create a small session that sends orders
sub c_connected
{
    my ($heap, $handle) = @_[HEAP, ARG0];
    POE::Session->new
    (   __PACKAGE__, [qw(_start error received)],
        [$handle]
    );
}


################################################
# Creating the session that sends stuff
sub _start
{
    my($heap, $handle)=@_[HEAP, ARG0];
    $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $handle,                    # on this handle
      Driver     => POE::Driver::SysRW->new(),  # using sysread and syswrite
      InputState => 'received',

      Filter     => POE::Filter::Stream->new(),
      ErrorState => 'error',            # generate this event on error
    );


    #############################
    # This is the list of stuff we want to send to the other side
    $heap->{send_these}=
    [
        # starts in Stream mode
        ## Switch between each type w/o any chance of buffering (easy)
        '"IWANT Line"',
        '"IWANT Stream\n"',
        '"IWANT Reference"',
        '{my $f = freeze(\ "IWANT Stream"); return length($f) . "\0" . $f}',
        '"IWANT Reference"',
        '{my $f = freeze(\ "IWANT Line"); return length($f) . "\0" . $f}',
        # now in Line mode

        ## Switch between 2 types w/ some extra stuff
        # NOTE-1 that switching Stream -> something will loose the
        # end of the something because Filter::Stream doesn't do any buffering
        # NOTE-2 Switching from Line -> something will cause problems
        # if the trailing data contains newlines.  While we can avoid
        # this if we switch to Stream, we can't when we switch to Reference

        '"IWANT Stream\nHELLO"',
        '"IWANT Reference"',
        '{my $f = freeze(\ "IWANT Line"); return length($f) . "\0" . $f . "HELLO
\n"}',
        '"IWANT Reference\n"',
        '{my $f = freeze(\ "IWANT Stream"); return length($f) . "\0" . $f . "HEL
LO"}',
        '"DONE"',
    ];
}

################################################
# I/O error or maybe disconnect
sub error
{
    my ($heap, $kernel, $operation, $errnum, $errstr) =
        @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if ($errnum)
    {
        print "Cause  [$$] encountered $operation error $errnum: $errstr\n"
    }
    else
    {
        print "Cause  [$$] remote closed its connection\n"
    }
                                        # either way, shut down
    delete $heap->{wheel_client};
}

################################################
# Other side sent us something

sub received
{
    my($heap, $buffer)=@_[HEAP, ARG0];

    my $ok=1;
    if($buffer=~s/^(\d+)\0//s)          # maybe from Filter::Reference
    {
        my $n=$1;
        $buffer=thaw(substr($buffer, 0, $n));
        $buffer=$$buffer;
    }

    if($buffer =~ /DONE/)               # Last message
    {
        delete $heap->{wheel_client};   # disconnect
        return;
    }
    if($buffer =~ /HI/)                 # response to our "HELLO"
    {
        print "Cause  [$$] how nice...\n";
        $ok=1;
    }
    if($buffer =~/NOT/)                 # something bad happened :(
    {
        print "Cause  [$$] something went wrong :(\n";
        exit;
    }
    if($buffer =~ /OK/)                 # it made the switch, now give it
    {                                   # another order
        my $send=shift @{$heap->{send_these}};
        if($send)
        {
            print "Cause  [$$] send '$send'\n";
            $send=eval($send);
            die $@ if $@;
            # print "Cause  [$$] send '", quotemeta($send), "'\n";
            $heap->{wheel_client}->put($send);
        } else
        {
            print "Finished...";            # unless we've run out of orders
            delete $heap->{wheel_client};   # Disconnect
        }
        $ok=1;
    }
    unless($ok)                             # Hmm... this message doesn't
    {                                       # make sense
        $buffer=quotemeta $buffer;
        print "Cause  [$$] received '$buffer'...\n";
        exit;
    }
}


##############################################################################

##############################################################################
## This is the listener side of the connection.  It receives orders from
## Cause, and jumps between Filters

package Effect;
use strict;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite
           Driver::SysRW Filter::Stream Filter::Line Filter::Reference
          );

################################################
# Create our top session
sub create
{
    my($port)=@_;
    POE::Session->new
    (
        '_start'=>\&e_start,
        'error'=>\&e_error,
        'accept'=>\&e_accept,
        [$port],
    );
}

################################################
# Start our top session
sub e_start
{
    my($heap, $port)=@_[HEAP, ARG0];
    $heap->{wheel} = new POE::Wheel::SocketFactory
    ( BindPort     => $port,
      BindAddress  => '127.0.0.1',
      Reuse         => 1,
      SuccessState   => 'accept',       # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );
}

################################################
# Some sort of error
sub e_error
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    print "Effect [$$] encountered $operation error $errnum: $errstr\n";
    delete $heap->{wheel};
}

################################################
# Effect has connected to us, so we now create a session for it
sub e_accept
{
    my ($heap, $handle) = @_[HEAP, ARG0];
    POE::Session->new
    (   __PACKAGE__, [qw(_start _stop error r_stream r_line r_reference)],
        [$handle]
    );
}

################################################
# Start of the connection session
# We start off with a Stream filter, because that is the simplest
sub _start
{
    my($heap, $session, $handle, $wheel)=@_[HEAP, SESSION, ARG0];

    # Create all the filters now
    $heap->{filters}=
    {
        Stream=>['r_stream', POE::Filter::Stream->new(), 0],
        Line=>['r_line', POE::Filter::Line->new(), 0],
        Reference=>['r_reference', POE::Filter::Reference->new(), 1],
    };

    $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $handle,                    # on this handle
      Driver     => POE::Driver::SysRW->new(),  # using sysread and syswrite
      ErrorState => 'error',            # generate this event on error

      InputState => $heap->{filters}->{Stream}->[0],
      Filter     => $heap->{filters}->{Stream}->[1],
    );
    _response($heap, "OK");                     # start the dialog
}

################################################
# Internal function -- Send a message back
sub _response
{
    my($heap, $resp)=@_;
    return unless $resp;
    print "Effect [$$] Send $resp\n";
    if($heap->{'ref'})
    {
        print "Effect [$$] As a reference...\n";
        $resp=\ "$resp";
    }

    $heap->{wheel_client}->put($resp);
}

################################################
# Internal funciont -- Decode and follow the order
sub _received
{
    my($heap, $current, $line)=@_;
    my $resp="OK";

    ## IWANT means Effect wants us to change filters
    if($line =~ /^IWANT (Line|Reference|Stream)$/)
    {
        my $type=$1;
        if($current ne $type)               # only do it if we aren't already
        {
            my $f=$heap->{filters}->{$type};
            if($f)
            {
                print "Effect [$$] Switching to $type\n";
                $heap->{wheel_client}->event(InputState=>$f->[0]);
                $heap->{wheel_client}->set_filter($f->[1]);
                $heap->{'ref'}=$f->[2];
            } else
            {
                                        # Effect is messed up
                print "Effect [$$] Unknown filter $type\n";
                $resp='NOT';
            }
        } else
        {
            print "Effect [$$] Already a $type\n";
        }
    } elsif($line eq 'HELLO')               # This is pending data
    {
        $resp='HI';
    } elsif($line eq 'DONE')                # Game over :)
    {
        print "Effect [$$] Done!\n";
        $resp='DONE';
    } else                                  # Something else... :(
    {
        print "Effect [$$] Hey! Received $current '$line'\n";
        $resp='NOT';
    }
    _response($heap, $resp);
}


################################################
# InputState when we are using Filter::Stream
sub r_stream
{
    my($heap, $data)=@_[HEAP, ARG0];
    _received($heap, 'Stream', $data);
}


################################################
# InputState when we are using Filter::Line
sub r_line
{
    my($heap, $line)=@_[HEAP, ARG0];
    _received($heap, 'Line', $line);
}

################################################
# InputState when we are using Filter::Referenece
sub r_reference
{
    my($heap, $reference)=@_[HEAP, ARG0];
    _received($heap, 'Reference', $$reference);
}


################################################
# I/O error or disconnection
sub error
{
    my ($heap, $kernel, $operation, $errnum, $errstr) =
        @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if ($errnum)
    {
        print "Effect [$$] encountered $operation error $errnum: $errstr\n";
    }
    else
    {
        print "Effect [$$] Remote closed its connection.\n";
    }
    delete $heap->{wheel_client};       # either way, shut down
}


################################################
# When this session shuts down, we also want to kill the kernel
sub _stop
{
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    $kernel->signal($kernel, 'HUP');
    delete $heap->{wheel_client};
}



##############################################################################
package main;
use strict;

use POE;

my $port=12345;
my $me;

my $pid=fork();                         # Split in two
if(not defined $pid)                    # wha?  we can't!
{
    die "Unable to fork: $!\n";
} elsif($pid)                           # Parent side
{
    Effect::create($port);              # Create a listener
    $me='Effect';
} else                                  # Child side
{
    sleep(2);                           # wait for Effect to come up
    Cause::create($port);               # create the caller
    $me='Cause ';
}

print "$me [$$] POE->run\n";
$poe_kernel->run();
print "$me [$$] Exit\n";
