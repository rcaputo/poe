# $Id: $
# vim: filetype=perl

# Tests propagation of signals through the session ancestry

use warnings;
use strict;

use Test::More;

plan 'no_plan';

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

{
	my @log;

	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$_[KERNEL]->sig("foo" => "foo");
				$_[KERNEL]->signal( $_[SESSION], "foo" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[STATE, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ leave_start => $session ],
			[ foo => $session ],
			[ stop => $session ],
		],
		"simple signal on one session",
	);
}

{
	my @log;

	my $child;
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$child = POE::Session->create(
					inline_states => {
						_start => sub {
							push @log, [ enter_start => $_[SESSION] ];
							$_[KERNEL]->delay("bar" => 0.1);
							push @log, [ leave_start => $_[SESSION] ];
						},
						_child   => sub { push @log, [ child => $_[SESSION] ] },
						_stop    => sub { push @log, [ stop => $_[SESSION] ] },
						_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
						foo      => sub { push @log, [ foo => $_[SESSION] ] },
					},
				);
				$_[KERNEL]->sig("foo" => "foo");
				$_[KERNEL]->signal( $_[SESSION], "foo" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ enter_start => $child ],
			[ leave_start => $child ],
			[ child => $session ],
			[ leave_start => $session ],
			[ foo => $session ],
			[ default => bar => $child ],
			[ stop => $child ],
			[ child => $session ],
			[ stop => $session ],
		],
		"signal on parent, oblivious child",
	);
}

{
	my @log;

	my $child;
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$child = POE::Session->create(
					inline_states => {
						_start => sub {
							push @log, [ enter_start => $_[SESSION] ];
							$_[KERNEL]->delay("bar" => 0.1);
							$_[KERNEL]->sig("foo" => "foo");
							push @log, [ leave_start => $_[SESSION] ];
						},
						_child   => sub { push @log, [ child => $_[SESSION] ] },
						_stop    => sub { push @log, [ stop => $_[SESSION] ] },
						_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
						foo      => sub { push @log, [ foo => $_[SESSION] ] },
					},
				);
				$_[KERNEL]->sig("foo" => "foo");
				$_[KERNEL]->signal( $_[SESSION], "foo" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ enter_start => $child ],
			[ leave_start => $child ],
			[ child => $session ],
			[ leave_start => $session ],
			[ foo => $child ],
			[ foo => $session ],
			[ default => bar => $child ],
			[ stop => $child ],
			[ child => $session ],
			[ stop => $session ],
		],
		"signal on child, then parent",
	);
}

{
	my @log;

	my $child;
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$child = POE::Session->create(
					inline_states => {
						_start => sub {
							push @log, [ enter_start => $_[SESSION] ];
							$_[KERNEL]->delay("bar" => 1);
							$_[KERNEL]->sig("TERM" => "TERM");
							push @log, [ leave_start => $_[SESSION] ];
						},
						_child   => sub { push @log, [ child => $_[SESSION] ] },
						_stop    => sub { push @log, [ stop => $_[SESSION] ] },
						_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
						foo      => sub { push @log, [ foo => $_[SESSION] ] },
					},
				);
				$_[KERNEL]->sig("TERM" => "TERM");
				$_[KERNEL]->signal( $_[SESSION], "TERM" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ enter_start => $child ],
			[ leave_start => $child ],
			[ child => $session ],
			[ leave_start => $session ],
			[ default => TERM => $child ],
			[ default => TERM => $session ],
			[ stop => $child ],
			[ child => $session ],
			[ stop => $session ],
		],
		"TERM signal on child, then parent",
	);
}

{
	my @log;

	my $child;
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$child = POE::Session->create(
					inline_states => {
						_start => sub {
							push @log, [ enter_start => $_[SESSION] ];
							$_[KERNEL]->delay("bar" => 1);
							push @log, [ leave_start => $_[SESSION] ];
						},
						_child   => sub { push @log, [ child => $_[SESSION] ] },
						_stop    => sub { push @log, [ stop => $_[SESSION] ] },
						_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
						foo      => sub { push @log, [ foo => $_[SESSION] ] },
					},
				);
				$_[KERNEL]->signal( $_[SESSION], "TERM" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ enter_start => $child ],
			[ leave_start => $child ],
			[ child => $session ],
			[ leave_start => $session ],
			[ stop => $child ],
			[ child => $session ],
			[ stop => $session ],
		],
		"TERM signal with no handlers on child, then parent",
	);
}

{
	my @log;

	my ( $child, $grandchild );
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$child = POE::Session->create(
					inline_states => {
						_start => sub {
							push @log, [ enter_start => $_[SESSION] ];
							$grandchild = POE::Session->create(
								inline_states => {
									_start => sub {
										push @log, [ enter_start => $_[SESSION] ];
										$_[KERNEL]->delay("bar" => 1);
										push @log, [ leave_start => $_[SESSION] ];
									},
									_child   => sub { push @log, [ child => $_[SESSION] ] },
									_stop    => sub { push @log, [ stop => $_[SESSION] ] },
									_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
									foo      => sub { push @log, [ foo => $_[SESSION] ] },
								},
							);
							$_[KERNEL]->sig( TERM => "TERM" );
							$_[KERNEL]->delay("bar" => 1);
							push @log, [ leave_start => $_[SESSION] ];
						},
						_child   => sub { push @log, [ child => $_[SESSION] ] },
						_stop    => sub { push @log, [ stop => $_[SESSION] ] },
						_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
						foo      => sub { push @log, [ foo => $_[SESSION] ] },
					},
				);
				$_[KERNEL]->signal( $_[SESSION], "TERM" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ enter_start => $child ],
			[ enter_start => $grandchild ],
			[ leave_start => $grandchild ],
			[ child => $child ],
			[ leave_start => $child ],
			[ child => $session ],
			[ leave_start => $session ],
			[ default => TERM => $child ],
			[ stop => $grandchild ],
			[ child => $child ],
			[ stop => $child ],
			[ child => $session ],
			[ stop => $session ],
		],
		"TERM signal on granchild, then child (with handler), then parent",
	);
}

{
	my @log;

	my ( $child, $grandchild );
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				push @log, [ enter_start => $_[SESSION] ];
				$child = POE::Session->create(
					inline_states => {
						_start => sub {
							push @log, [ enter_start => $_[SESSION] ];
							$grandchild = POE::Session->create(
								inline_states => {
									_start => sub {
										push @log, [ enter_start => $_[SESSION] ];
										$_[KERNEL]->delay("bar" => 1);
										push @log, [ leave_start => $_[SESSION] ];
									},
									_child   => sub { push @log, [ child => $_[SESSION] ] },
									_stop    => sub { push @log, [ stop => $_[SESSION] ] },
									_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
									foo      => sub { push @log, [ foo => $_[SESSION] ] },
								},
							);
							$_[KERNEL]->delay("bar" => 1);
							push @log, [ leave_start => $_[SESSION] ];
						},
						_child   => sub { push @log, [ child => $_[SESSION] ] },
						_stop    => sub { push @log, [ stop => $_[SESSION] ] },
						_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
						foo      => sub { push @log, [ foo => $_[SESSION] ] },
					},
				);
				$_[KERNEL]->signal( $_[SESSION], "TERM" );
				push @log, [ leave_start => $_[SESSION] ];
			},
			_child   => sub { push @log, [ child => $_[SESSION] ] },
			_stop    => sub { push @log, [ stop => $_[SESSION] ] },
			_default => sub { push @log, [ default => @_[ARG0, SESSION] ] },
			foo      => sub { push @log, [ foo => $_[SESSION] ] },
		},
	);

	POE::Kernel->run;

	is_deeply(
		\@log,
		[
			[ enter_start => $session ],
			[ enter_start => $child ],
			[ enter_start => $grandchild ],
			[ leave_start => $grandchild ],
			[ child => $child ],
			[ leave_start => $child ],
			[ child => $session ],
			[ leave_start => $session ],
			[ stop => $grandchild ],
			[ child => $child ],
			[ stop => $child ],
			[ child => $session ],
			[ stop => $session ],
		],
		"TERM signal with no handlers on granchild, then child, then parent",
	);
}
