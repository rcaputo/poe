# $Id$
# vim: filetype=perl

use Test::More;
eval "use Test::Pod::Coverage 1.00";
plan skip_all => "Test::Pod::Coverage 1.00 required for testing POD coverage"
  if $@;
plan skip_all => 'set POE_TEST_POD or POE_TEST_POD_STRICT to enable this test'
  unless $ENV{POE_TEST_POD} or $ENV{POE_TEST_POD_STRICT};

my $strict = $ENV{POE_TEST_POD_STRICT};

# These are the default Pod::Coverage options.
my $default_opts = {
  also_private => [
    qr/^[A-Z0-9_]+$/,      # Constant subroutines.
  ],
};

# Special case modules. Only define modules here if you want to skip
# (0) or apply different Pod::Coverage options ({}).  These options
# clobber $default_opts above, so be sure to duplicate the default
# options you want to keep.

my %special = (
  'POE::Kernel' => {
    also_private => [
      qr/^[A-Z0-9_]+$/,
      ( $strict
        ? ( )
        : (
          'finalize_kernel',      # Should be _finalize_kernel.
          'get_event_count',      # Should this exist?
          'get_next_event_time',  # Should this exist?
          'new',                  # Definitely private.  Necessary?
          'queue_peek_alarms',    # Public or private?
          'session_alloc',        # Should be documented.
        )
      )
    ],
  },
  'POE::Session' => {
    also_private => [
      qr/^[A-Z0-9_]+$/,
      ( $strict
        ? ( )
        : (
          'register_state',        # Should become _register_state.
          'instantiate',          # Public or private?
          'try_alloc',            # Public or private?
        )
      )
    ],
  },
  'POE::NFA' => {
    also_private => [
      qr/^[A-Z0-9_]+$/,
      ( $strict
        ? ( )
        : (
          'register_state',        # Should become _register_state.
        )
      )
    ],
  },
  'POE::Wheel::ReadLine' => {
    also_private => [
      qr/^[A-Z0-9_]+$/,            # Constants subs.
      qr/^rl_/,                    # Keystroke callbacks.
      ( $strict
        ? ( )
        : (
          'option',                # Should this be public or private?
          'search',                # Should this be public or private?
        )
      )
    ],
    coverage_class => 'Pod::Coverage::CountParents'
  },
);

my @modules = all_modules();

plan tests => scalar @modules;

foreach my $module ( @modules ) {
  my $opts = $default_opts;

  # Modules that inherit documentation from their parents.
  if ( $module =~ /^POE::(Loop|Driver|Filter|Wheel|Queue)::/ ) {
    $opts = {
      %$default_opts,
      coverage_class => 'Pod::Coverage::CountParents',
    };
  }
  SKIP: {
    if ( exists $special{$module} ) {
      skip "$module", 1 unless $special{$module};
      $opts = $special{$module} if ref $special{$module} eq 'HASH';
    }
    pod_coverage_ok( $module, $opts );
  }
}
