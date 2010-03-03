#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 3;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

BEGIN { use_ok("IO::Poll") }

BEGIN { use_ok("POE") }

is( $poe_kernel->poe_kernel_loop(), 'POE::Loop::IO_Poll', "POE found the right loop" );
