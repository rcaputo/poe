#!/usr/bin/perl

use strict;
use warnings;

sub DEBUG () { 0 }
sub POE::Kernel::USE_SIGCHLD () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;
use Test::More;
use POE::Wheel::Run;
use POSIX qw( SIGINT );

if ($^O eq "MSWin32") {
	plan skip_all => "Test not working on $^O";
	exit 0;
}

plan tests => 5;

POE::Session->create(
	inline_states => {
		_start => \&_start,
		_stop  => \&_stop,
		stdout => \&stdout,
		stdout2 => \&stdout2,
		stderr => \&stderr,
		sig_CHLD => \&sig_CHLD,
		error  => \&error,
		done   => \&done
	}
);

$poe_kernel->run;
pass( "Sane exit" );
exit;

sub _start {
	my( $kernel, $heap ) = @_[KERNEL, HEAP];

	my $prog = <<'PERL';
		$|++;
		my $N = shift;
		print "I am $N\n";
		while(<STDIN>) {
			chomp;
			exit 0 if /^bye/;
			print "Unknown command '$_'\n";
		}
PERL

	DEBUG and warn "_start";
	$kernel->alias_set( 'worker' );
	$kernel->sig( CHLD => 'sig_CHLD' );

	$heap->{W1} = POE::Wheel::Run->new(
		Program => [ $^X, '-e', $prog, "W1" ],
		StdoutEvent => 'stdout',
		StderrEvent => 'stderr',
		ErrorEvent  => 'error'
	);
	$heap->{id2W}{ $heap->{W1}->ID } = 'W1';
	$heap->{pid2W}{ $heap->{W1}->PID } = 'W1';

	$heap->{W2} = POE::Wheel::Run->new(
		Program => [ $^X, '-e', $prog, "W2" ],
		StdoutEvent => 'stdout',
		StderrEvent => 'stderr',
		ErrorEvent  => 'error'
	);
	$heap->{id2W}{ $heap->{W2}->ID } = 'W2';
	$heap->{pid2W}{ $heap->{W2}->PID } = 'W2';
}

sub _stop {
	my( $kernel, $heap ) = @_[KERNEL, HEAP];
	DEBUG and warn "_stop";
}

sub done {
	my( $kernel, $heap ) = @_[KERNEL, HEAP];
	DEBUG and warn "done";

	$kernel->alias_remove( 'worker' );
	$kernel->sig( 'CHLD' );

	delete $heap->{W1};
	delete $heap->{W2};

	my @list = keys %{ $heap->{pid2W} };
	is( 0+@list, 1, "One wheel left" );
	kill SIGINT, @list;

	alarm(5); $SIG{ALRM} = sub { die "test case didn't end sanely" };
}

sub stdout {
	my( $kernel, $heap, $input, $id ) = @_[KERNEL, HEAP, ARG0, ARG1];
	my $N = $heap->{id2W}{$id};
	DEBUG and warn "Input $N ($id): '$input'";
	my $wheel = $heap->{ $N };
	ok( ($input =~ /I am $N/), "Intro output" );
	if( $N eq 'W1' ) {
		$heap->{closing}{ $N } = 1;
		$wheel->put( 'bye' );
	}
}

sub stderr {
	my( $kernel, $heap, $input, $id ) = @_[KERNEL, HEAP, ARG0, ARG1];
	my $N = $heap->{id2W}{$id};
	DEBUG and warn "Error $N ($id): '$input'";
}

sub error {
	my( $kernel, $heap, $op, $errnum, $errstr, $id, $fh ) = @_[
		KERNEL, HEAP, ARG0..$#_
	];

	my $N = $heap->{id2W}{$id};
	DEBUG and warn "Error $N ($id): $op $errnum ($errstr)";
	my $wheel = $heap->{ $N };

	if( $op eq 'read' and $errnum==0 ) {
		# normal exit
	}
	else {
		die "Error $N ($id): $op $errnum ($errstr)";
	}
}

sub sig_CHLD {
	my( $kernel, $heap, $signal, $pid, $status ) = @_[
		KERNEL, HEAP, ARG0..$#_
	];

	my $N = $heap->{pid2W}{$pid};
	DEBUG and warn "CHLD $N ($pid)";
	my $wheel = $heap->{ $N };

	is( $heap->{closing}{$N}, 1, "$N closing" );

	delete $heap->{closing}{$N};
	delete $heap->{pid2W}{$pid};
	delete $heap->{$N};
	delete $heap->{id2W}{ $wheel->ID };
	$kernel->yield( 'done' );
}
