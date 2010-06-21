#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 1;
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

TODO: {
  local $TODO = 'This needs to be investigated someday...';

  # Hide warnings.
  {
    local $SIG{__WARN__} = sub { undef };
    # This relies on the assumption that loading POE defaults to PoLo::Select!
    eval "use POE; use POE::Kernel { loop => 'IO_Poll' };";
  }
  ok($@, "loading a loop throws an error if a loop was already loaded");
}
