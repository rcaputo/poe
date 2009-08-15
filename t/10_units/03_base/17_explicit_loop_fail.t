#!/usr/bin/perl -w

use strict;

use Test::More tests => 1;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

# Hide warnings.
{
	local $SIG{__WARN__} = sub { undef };
	eval "use POE qw(Loop::NightMooseDontExist)";
}
ok($@, "loading a nonexistent loop throws an error");
