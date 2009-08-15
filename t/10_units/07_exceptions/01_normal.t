# vim: filetype=perl

use Test::More tests => 7;

use POE;

POE::Session->create(
  inline_states => {
    _start => sub {
      pass("Session started");
      $_[KERNEL]->sig('DIE' => 'avoid_death');
      $_[KERNEL]->yield('death');
      $_[KERNEL]->delay('party' => 0.5);
    },

    _stop => sub { pass("Session stopping"); },

    death => sub { die "OMG THEY CANCELLED FRIENDS"; },

    avoid_death => sub {
      my $signal = $_[ARG0];
      my $data = $_[ARG1];
      is($signal, 'DIE', 'Caught DIE signal');
      is($data->{from_state}, '_start', 'Signal came from the correct state');
      like($data->{error_str}, qr/OMG THEY CANCELLED FRIENDS/, 'error_str contains correct value');
      $_[KERNEL]->sig(DIE => undef);
      $_[KERNEL]->sig_handled();
    },
    party => sub { pass("Environment survived exception attempt"); },
  },
);

POE::Kernel->run();

pass("POE environment shut down");
