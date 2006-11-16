#!perl
# $Id$
# vim: filetype=perl

# Calling sig_child($pid) without a prior sig_child($pid, $event)
# would drop the session's reference count below zero.

use warnings;
use strict;

use Test::More tests => 1;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

POE::Session->create(
	inline_states => {
		_start => sub { $_[KERNEL]->yield("test") },
		test   => sub { $_[KERNEL]->sig_child(12) },
		_stop  => sub { pass("didn't die") },
	}
);

POE::Kernel->run();
