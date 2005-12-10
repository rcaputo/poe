# $Id$

use Test::More tests => 6; 

use POE;

POE::Session->create(
	inline_states => {
		_start => sub {
			pass("Session started");
			$_[KERNEL]->sig('DIE' => 'mock_death');
			$_[KERNEL]->yield('death');
		},

		_stop => sub { pass("Session stopping"); },

		death => sub { die "OMG THEY CANCELLED FRIENDS"; },
		mock_death => sub { is($_[ARG0], 'DIE', "DIE signal sent"); },
	},
);

POE::Session->create(
	inline_states => {
		_start => sub {
			pass("Other session started");
			$_[KERNEL]->delay('last_breath' => 0.5);
		},

		_stop => sub { pass("Other session stopping"); },
		
		last_breath => sub { fail("POE environment survived uncaught exception"); },
	},
);

POE::Kernel->run();
pass("POE environment shut down");


# sungo // vim: ts=4 sw=4 noexpandtab
