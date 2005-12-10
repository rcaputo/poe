#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl

# Welcome to recursive signals, this test makes sure that the sig_handled()
# flag does not affect outer signals.

use strict;

sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

use Test::More tests => 4;

my $i = 0;

POE::Session->create(
	inline_states => {
		_start => sub {
			ok( ++$i == 1, "Second session startup" );
			$_[KERNEL]->sig( 'HUP', 'hup' );
			$_[KERNEL]->sig( 'DIE', 'death' );
			$_[KERNEL]->signal( $_[SESSION], 'HUP' );
			$_[KERNEL]->yield( 'bad' );
		},
		bad => sub {
			fail( "We shouldn't get here" );
		},
		hup => sub {
			ok( ++$i == 2, "HUP handler" );
			my $foo = undef;
			$foo->put(); # oh my!
		},
		death => sub {
			ok( ++$i == 3, "DIE handler" );
			$_[KERNEL]->sig_handled();
		},
		_stop => sub {
			ok( ++$i == 4, "Session shutdown" );
		},
	},
);

POE::Kernel->run();
