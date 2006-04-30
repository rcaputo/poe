#!/usr/bin/perl
# $Id$
# vim: filetype=perl

use warnings;
use strict;

use POE;
use Test::More tests => 3;

my $test_state  = "some_random_state";
my @test_args   = qw(some random args);

POE::Session->create(
	inline_states => {
		_start => sub {
			$_[KERNEL]->yield($test_state, @test_args);
		},
		_default => sub {
			my ($orig_state, $orig_args) = @_[ARG0,ARG1];
			if ($orig_state eq $test_state) {
				is_deeply(\@test_args, $orig_args, "test args passed okay");
			}

			$_[KERNEL]->yield( check_ref  => $_[ARG1]      );
			$_[KERNEL]->yield( check_copy => [@{$_[ARG1]}] );
		},
		check_ref => sub {
			my $test_args = $_[ARG0];
			is_deeply(
				\@test_args, $test_args,
				"args preserved in pass by reference",
			);
		},
		check_copy => sub {
			my $test_args = $_[ARG0];
			is_deeply(
				\@test_args, $test_args,
				"args preserved in pass by copy",
			);
		}
	}
);

POE::Kernel->run;
exit 0;
