#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 2;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

TODO: {
  local $TODO = 'This feature is not implemented yet';

  # Hide warnings.
  {
	  local $SIG{__WARN__} = sub { undef };
    eval "use POE::Loop::IO_Poll; use POE";
  }

  ok(! $@, "Loading a loop the naive way doesn't explode");

  # Hide warnings.
  my $loop_loaded;
  {
	  local $SIG{__WARN__} = sub { undef };
    eval '$loop_loaded = $poe_kernel->poe_kernel_loop()';
  }

  if ( ! $@ ) {
    is( $loop_loaded, 'POE::Loop::IO_Poll', "POE loaded the right loop" );
  } else {
    ok( 0, "Dummy test for TODO" );
  }
}
