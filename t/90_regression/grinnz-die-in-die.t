#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 3;
use POE;

POE::Session->create(
	inline_states => {
		_start => sub {
			$_[KERNEL]->sig(DIE => 'sig_DIE');
			die 'original error';
		},
		sig_DIE => sub {
			my $exception = $_[ARG1];
			my $event = $exception->{'event'};
			my $error = $exception->{'error_str'};

			chomp $error;

			is($event, '_start', "die in $event caught");

			die 'error in error handler';

			# The die() above bypasses this call.
			POE::Kernel->sig_handled();
		},
	}
);

eval {
	POE::Kernel->run();
};

like(
	$@, qr/original error/,
	"run() rethrown exception contains original error"
);

like(
	$@, qr/error in error handler/,
	"run() rethrown exception contains error in error handler"
);
