#!/usr/bin/perl -w -I..
# $Id$

# This program tests the ability of Filter::Reference to use "any"
# package or object for freeze/thaw.

###############################################################################
# This is the caller.

package Cause;
use strict;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW
           Filter::Reference
          );

###############################################
# Create our top session
sub create
{
    my($port, $freezer)=@_;
    POE::Session->new
    (
        _start=>\&c_start,
        error=>\&c_error,
        connected=>\&c_connected,
        [$port, $freezer],
    );
}

###############################################
# Start the top session
sub c_start
{
    my($heap, $port, $freezer)=@_[HEAP, ARG0, ARG1];
    $heap->{wheel} = new POE::Wheel::SocketFactory
    ( RemotePort     => $port,
      RemoteAddress  => '127.0.0.1',
      SuccessState   => 'connected',    # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );
    $heap->{freezer}=$freezer;
}

###############################################
# Errors at connect time
sub c_error
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    print "Cause encountered $operation error $errnum: $errstr\n";
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
        [$handle, $heap->{freezer}]
    );
}


################################################
# Creating the session that sends stuff
sub _start
{
    my($heap, $handle, $freezer)=@_[HEAP, ARG0, ARG1];

    $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $handle,                    # on this handle
      Driver     => POE::Driver::SysRW->new(),  # using sysread and syswrite
      InputState => 'received',

      Filter     => POE::Filter::Reference->new($freezer),
      ErrorState => 'error',            # generate this event on error
    );

    my $t=\ "Using $freezer";
    ::note('Cause  ask', $t);
    $heap->{wheel_client}->put($t);     # start off the dialog
}


################################################
# Other side sent us something

sub received
{
    my($heap, $ref)=@_[HEAP, ARG0];
    ::note('Cause  answer', $ref);
    delete $heap->{wheel_client};       # Shut down
}

################################################
# I/O error or maybe disconnect
sub error
{
    my ($heap, $kernel, $operation, $errnum, $errstr) =
        @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if ($errnum)
    {
        print "Cause  encountered $operation error $errnum: $errstr\n"
    }
    else
    {
        print "Cause  remote closed its connection\n"
    }
                                        # either way, shut down
    delete $heap->{wheel_client};
}



##############################################################################

##############################################################################
## This is the listener side of the connection.  It receives orders from
## Cause, and jumps between Filters

package Effect;
use strict;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite
            Driver::SysRW Filter::Reference);

################################################
# Create our top session
sub create
{
    my($port, $freezer)=@_;
    POE::Session->new
    (
        '_start'=>\&e_start,
        'error'=>\&e_error,
        'accept'=>\&e_accept,
        [$port, $freezer],
    );
}

################################################
# Start our top session
sub e_start
{
    my($heap, $port, $freezer)=@_[HEAP, ARG0, ARG1];
    $heap->{wheel} = new POE::Wheel::SocketFactory
    ( BindPort     => $port,
      BindAddress  => '127.0.0.1',
      Reuse         => 1,
      SuccessState   => 'accept',       # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );
    $heap->{freezer}=$freezer;
}

################################################
# Some sort of error
sub e_error
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    print "Effect encountered $operation error $errnum: $errstr\n";
    delete $heap->{wheel};
}

################################################
# Effect has connected to us, so we now create a session for it
sub e_accept
{
    my ($heap, $handle) = @_[HEAP, ARG0];
    POE::Session->new
    (   __PACKAGE__, [qw(_start _stop error received)],
        [$handle, $heap->{freezer}]
    );
}

################################################
# Start of the connection session
sub _start
{
    my($heap, $session, $handle, $freezer)=@_[HEAP, SESSION, ARG0, ARG1];

    $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $handle,                    # on this handle
      Driver     => POE::Driver::SysRW->new(),  # using sysread and syswrite
      ErrorState => 'error',            # generate this event on error

      InputState => 'received',
      Filter     => POE::Filter::Reference->new($freezer),
    );
    $heap->{resp}=\ "Using $freezer";
}

################################################
# InputState when we are using Filter::Referenece
sub received
{
    my($heap, $reference)=@_[HEAP, ARG0];
    my $ref=$heap->{resp};
    if($$reference ne $$ref)
    {
        die "$$reference isn't $$ref. NO WAY!\n";
    }
    ::note('Effect was asked', $reference);
    ::note('Effect did answer', $ref);
    $heap->{wheel_client}->put($ref);
}


################################################
# I/O error or disconnection
sub error
{
    my ($heap, $kernel, $operation, $errnum, $errstr) =
        @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if ($errnum)
    {
        print "Effect encountered $operation error $errnum: $errstr\n";
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
## Small freeze/thaw er that uses Dumper and eval
package Bogus;
use strict;
use Data::Dumper;
use Carp;

sub new
{
    my $type=shift;
    my $t='';
    return bless \$t, $type;
}

sub freeze
{
    my ($self, $ref)=@_;
    local $Data::Dumper::Purity=1;
    local $Data::Dumper::Indent=0;
    local $Data::Dumper::Useqq=0;
    return Dumper $ref;
}

sub thaw
{
    my ($self, $data)=@_;
    my $VAR1;
    eval $data;
    croak "Corrupted reference: $@\n" if $@;
    return $VAR1;
}

##############################################################################
# Meanwhile back at the ranch...
package main;
use strict;

use Data::Dumper;
use POE;


my $port=12345;
my $f;
foreach my $freezer ('', qw(Storable FreezeThaw), Bogus->new())
{
    Effect::create($port, $freezer);    # Create a listener
    sleep(1);                           # wait for Effect to come up
    Cause::create($port, $freezer);     # create the caller

    $f=$freezer||'default';
    print "$f POE->run\n";
    $poe_kernel->run();
    print "$f done.\n\n";
}

################################################
sub note
{
    my($msg, $ref)=@_;
    local $Data::Dumper::Indent=0;
    local $Data::Dumper::Terse=1;
    local $Data::Dumper::Useqq=0;
    $ref=Dumper($ref);
    print "$msg $ref\n";
}
