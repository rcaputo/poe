#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;
use warnings;

use Test::More;
use File::Spec;
use POE qw( Wheel::Run );

plan tests => 4;

foreach my $t ( qw( real fake ) ) {
  my_spawn( $t );
}

$poe_kernel->run();
exit 0;

sub my_spawn {
	POE::Session->create(
		package_states => [
			'main' => [qw(_start _stop _timeout _wheel_stdout _wheel_stderr _wheel_closed _wheel_child)],
		],
		'args' => [ $_[0] ],
	);
}

sub _start {
	my ($kernel,$heap,$type) = @_[KERNEL,HEAP,ARG0];

	$heap->{type} = $type;

	my $perl;
	if ( $type eq 'fake' ) {
		my @path = qw(COMPLETELY MADE UP PATH TO PERL);
		unshift @path, 'C:' if $^O eq 'MSWin32';
		$perl = File::Spec->catfile( @path );
	} elsif ( $type eq 'real' ) {
		$perl = $^X;
	}

	my $program = [ $perl, '-e', 1 ];

	$heap->{wheel} = POE::Wheel::Run->new(
		Program     => $program,
		StdoutEvent => '_wheel_stdout',
		StderrEvent => '_wheel_stderr',
		ErrorEvent  => '_wheel_error',
		CloseEvent  => '_wheel_closed',
	);

	$kernel->sig_child( $heap->{wheel}->PID, '_wheel_child' );
	$kernel->delay( '_timeout', 60 );
	return;
}

sub _wheel_stdout {
	return;
}

sub _wheel_stderr {
	return;
}

sub _wheel_closed {
	delete $_[HEAP]->{wheel};
	return;
}

sub _wheel_child {
  my $exitval = $_[ARG2];

  if ( $_[HEAP]->{type} eq 'real' ) {
    is( $exitval, 0, "Set proper exitval for '" . $_[HEAP]->{type} . "'" );
  } else {
    cmp_ok( $exitval, '>', 0, "Set proper exitval for '" . $_[HEAP]->{type} . "'" );
  }

	$poe_kernel->sig_handled();
	$poe_kernel->delay( '_timeout' );
	return;
}

sub _stop {
	pass("we sanely died (" . $_[HEAP]->{type} . ")");
	return;
}

sub _timeout {
	die "Something went seriously wrong";
	return;
}

