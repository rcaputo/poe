#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl


# System shouldn't fail in this case.

use strict;

sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

use Test::More tests => 3;

my $command = "/bin/true";

SKIP: {
	my @commands = grep { -x } qw(/bin/true /usr/bin/true);
	skip( "Couldn't find a command to run under system()", 3 ) unless @commands;

	my $command = shift @commands;

	diag( "Using '$command' as our thing to run under system()" );
	
	POE::Session->create(
		inline_states => {
			_start => sub {
				diag( "SIG{CHLD}: $SIG{CHLD}" );
				is( system( $command ), 0, "System returns properly" );
				diag( '$!: ' . $! );
				$! = undef;
				
				$_[KERNEL]->sig( 'CHLD', 'chld' );
				
				diag( "SIG{CHLD}: $SIG{CHLD}" );
				is( system( $command ), 0, "System returns properly" );
				diag( '$!: ' . $! );
				$! = undef;
				
				$_[KERNEL]->sig( 'CHLD' );

				diag( "SIG{CHLD}: $SIG{CHLD}" );
				is( system( $command ), 0, "System returns properly" );
				diag( '$!: ' . $! );
				$! = undef;
			},
			chld => sub {
				diag( "Caught child" );
			},
		}
	);
}

POE::Kernel->run();
