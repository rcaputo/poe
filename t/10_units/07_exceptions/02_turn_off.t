# vim: ts=2 sw=2 filetype=perl expandtab
use Test::More tests => 3;

sub POE::Kernel::CATCH_EXCEPTIONS () { 0 }
use POE;

eval {
  POE::Session->create(
    inline_states => {
      _start => sub {
        pass("Session started");
        $_[KERNEL]->yield('death');
      },

      _stop => sub { pass("Session stopping"); },

      death => sub { die "OMG THEY CANCELLED FRIENDS"; },
    },
  );

  POE::Kernel->run();
};

ok(length $@, "die caused normal exception");
like($@, qr/OMG THEY CANCELLED FRIENDS/, '$@ contains correct error message');
