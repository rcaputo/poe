#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 1;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

# Hide warnings.
{
	local $SIG{__WARN__} = sub { undef };
  eval "use POE::Kernel { loop => 'NightMooseDontExist' }";
}
ok($@, "loading a nonexistent loop throws an error");
