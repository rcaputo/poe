#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl


# System shouldn't fail in this case.

use strict;

sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

use Test::More tests => 2;

my $command = "/bin/true";

SKIP: {
	skip( "$command is necessary for this test", 2 ) unless -x $command;
	
	POE::Session->create(
		inline_states => {
			_start => sub {
				diag( "SIG{CHLD}: $SIG{CHLD}" );
				is( system( $command ), 0, "System returns properly" );
				
				$_[KERNEL]->sig( 'CHLD', 'chld' );
				
				diag( "SIG{CHLD}: $SIG{CHLD}" );
				is( system( $command ), 0, "System returns properly" );
				
				$_[KERNEL]->sig( 'CHLD' );
			},
			chld => sub {
				diag( "Caught child" );
			},
		}
	);
}

POE::Kernel->run();
