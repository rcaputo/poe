#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# While Apocalypse was debugging RT#65460 he noticed that POE took a long
# time to exit if TRACE_STATISTICS was enabled. It messed up the select
# timeout, and causing the internals to go boom! We've removed TRACE_STATISTICS
# but this test will remain here in case we screw up in the future :)

BEGIN {
  # perl-5.6.x on Win32 does not support alarm()
  if ( $^O eq 'MSWin32' and $] < 5.008 ) {
    print "1..0 # Skip perl-5.6.x on $^O does not support alarm()";
    exit();
  }

  # enable full tracing/asserts
  sub POE::Kernel::TRACE_DEFAULT () { 1 }
  sub POE::Kernel::ASSERT_DEFAULT () { 1 }

  # make sure tracing don't show up in STDOUT
  $SIG{'__WARN__'} = sub { return };
}

use POE;
use Test::More tests => 1;

POE::Session->create(
  inline_states => {
    _start => sub {
      $poe_kernel->yield( "do_test" );
      return;
    },
    do_test => sub {
      $poe_kernel->delay( "done" => 1 );
      return;
    },
    done => sub {
      return;
    },
  },
);

$SIG{ALRM} = sub { die 'timeout' };
alarm(10); # set to 10 for slow VMs, lower at your own peril :)
eval { POE::Kernel->run };
$SIG{ALRM} = "IGNORE";
ok( ! $@, "POE exited in time" );
