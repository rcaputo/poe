#!/usr/bin/env perl
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;
use warnings;
use POE;
use Test::More tests => 1;

POE::Session->create(
	package_states => [
		(__PACKAGE__) => [ qw( _start exit timeout) ],
	],
);

POE::Kernel->run;

sub _start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$kernel->delay('timeout', 5);
	$heap->{quickie} = WheelWrapper->new(
		Program   => sub { die },
		ExitEvent => 'exit',
	);
}

sub exit {
	my ($kernel, $heap, $status) = @_[KERNEL, HEAP, ARG0];
	isnt(($status >> 8), 0, 'Got exit status');
	$kernel->delay('timeout');
	$heap->{quickie}->shutdown();
}

sub timeout {
	fail('Timed out');
	$_[KERNEL]->signal($_[KERNEL], "DIE");
}

package WheelWrapper;

use strict;
use warnings;
use POE;
use POE::Wheel::Run;

sub new {
	my ($package, %args) = @_;
	my $self = bless \%args, $package;

	$self->{parent_id} = POE::Kernel->get_active_session->ID;

	POE::Session->create(
		object_states => [
			$self => [
				qw(
					_start
					_delete_wheel
					_child_signal
					_child_closed
					_shutdown
					)
			],
		],
	);

	return $self;
}

sub _start {
	my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];

	my $session_id = $session->ID;
	$self->{session_id} = $session_id;
	$kernel->refcount_increment($session_id, __PACKAGE__);

	my $wheel;
	eval {
		$wheel = POE::Wheel::Run->new(
			CloseEvent  => '_child_closed',
			StdoutEvent => 'dummy',
			Program     => $self->{Program},
		);
	};

	if ($@) {
		chomp $@;
		warn $@, "\n";
		return;
	}

	$self->{wheel} = $wheel;
	$self->{alive} = 2;
	$kernel->sig_child($wheel->PID, '_child_signal');
}

sub _child_signal {
	my ($kernel, $self, $pid, $status) = @_[KERNEL, OBJECT, ARG1, ARG2];
	my $id = $self->{wheel}->PID;
	$kernel->post($self->{parent_id}, $self->{ExitEvent}, $status);
	$kernel->yield('_delete_wheel', $id);
}

sub _child_closed {
	$_[KERNEL]->yield('_delete_wheel');
}

sub _delete_wheel {
	$_[OBJECT]->{alive}--;
	delete $_[OBJECT]->{wheel} if $_[OBJECT]->{alive} == 0;
}

sub shutdown {
	$poe_kernel->call($_[0]->{session_id}, '_shutdown');
}

sub _shutdown {
	$_[KERNEL]->refcount_decrement($_[OBJECT]->{session_id}, __PACKAGE__);
}
