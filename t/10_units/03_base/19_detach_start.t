#!/usr/bin/env perl -w

use strict;
use warnings;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use Test::More tests => 7;
use POE;

my $_child_fired = 0;

POE::Session->create(
	inline_states => {
		_start => sub {
			$_[KERNEL]->alias_set('First');
			pass "_start First";

			POE::Session->create(
				inline_states => {
					_start => sub {
						$_[KERNEL]->alias_set('Second');
						pass "_start Second";
					},
					_stop => sub { undef },
				},
			);

			POE::Session->create(
				inline_states => {
					_start => sub {
						$_[KERNEL]->alias_set('Detached');
						pass "_start Detached";
						$_[KERNEL]->detach_myself;
					},
					_parent => sub { undef },
					_stop => sub { undef },
				},
			);

		},
		_child => sub {
			$_child_fired++;
			ok(
				$_[KERNEL]->alias_list($_[ARG1]) ne 'Detached',
				"$_[STATE]($_[ARG0]) fired for " . $_[KERNEL]->alias_list($_[ARG1]->ID)
			);
		},
		_stop => sub { undef },
	},
);

POE::Kernel->run();

pass "_child not fired for session detached in _start"
	unless $_child_fired != 2;
pass "Stopped";

