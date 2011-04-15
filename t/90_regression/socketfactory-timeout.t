#!/usr/bin/env perl

use strict;
use warnings;
use POE qw(Wheel::SocketFactory);
use Test::More tests => 1;

POE::Session->create(
    package_states => [
        main => [qw(_start sock_up sock_down timeout)],
    ],
);

$poe_kernel->run();

sub _start {
    $_[HEAP]->{socket} = POE::Wheel::SocketFactory->new(
        SocketProtocol => 'tcp',
        RemoteAddress  => 'localhost',
        RemotePort     => 0,
        SuccessEvent   => 'sock_up',
        FailureEvent   => 'sock_down',
    );
    $_[KERNEL]->delay('timeout', 5);
}

sub sock_up {
    fail("Successful connection to an unused port?"),
    delete $_[HEAP]->{socket};
    $_[KERNEL]->delay('timeout');
}

sub sock_down {
    pass("Failed to connect as expected");
    delete $_[HEAP]->{socket};
    $_[KERNEL]->delay('timeout');
}

sub timeout {
    fail("Timed out before getting SuccessEvent or FailureEvent");
}
