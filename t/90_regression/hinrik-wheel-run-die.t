#!/usr/bin/env perl
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;
use warnings;
use Test::More;
use POE qw(Wheel::Run);

plan tests => 2;

POE::Session->create(
	package_states => [
		(__PACKAGE__) => [ qw( _start _child timeout) ]
	],
);

POE::Kernel->run();
exit;

sub _start {
	$_[KERNEL]->delay('timeout', 5);

	POE::Session->create(
		inline_states => {
			_start => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];

				$heap->{wheel} = POE::Wheel::Run->new(
					Program     => sub { die },
					StderrEvent => 'dummy',
					CloseEvent  => 'closure',
				);

				$kernel->sig_child($heap->{wheel}->PID, 'closure');
			},

			closure => sub {
        return unless ++$_[HEAP]{dead} == 2;
				delete $_[HEAP]{wheel};
        pass("POE::Wheel::Run closed");
			},
		},
	);
}

sub _child {
	my ($kernel, $heap, $reason) = @_[KERNEL, HEAP, ARG0];
	return if $reason eq 'create';

	$kernel->delay('timeout');
	is($reason, 'lose', 'Subsession died');
}

sub timeout {
	fail('Timed out');
	$_[KERNEL]->signal($_[KERNEL], "DIE");
}
