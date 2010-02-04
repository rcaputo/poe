# vim: ts=2 sw=2 filetype=perl expandtab

# This testcase loads all POE modules.  Some of them may define
# alternative methods with the same full-qualified names.  Disable the
# inevitable warnings.
BEGIN { $^W = 0 }

use Test::More;

unless ( $ENV{RELEASE_TESTING} ) {
  plan skip_all => 'enable by setting RELEASE_TESTING';
}

eval "use Test::Pod::Coverage 1.08";
plan skip_all => "Test::Pod::Coverage 1.08 required for testing POD coverage" if $@;

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
  'POE::Wheel::ReadLine' => {
    also_private => [
      qr/^[A-Z0-9_]+$/,            # Constants subs.
      qr/^rl_/,                    # Keystroke callbacks.
      # Deprecated names.
      qw( Attribs GetHistory ReadHistory WriteHistory addhistory ),
    ],
    coverage_class => 'Pod::Coverage::CountParents',
  },
  'POE::Kernel' => {
    %$default_opts,
    trustme => [ qr/^loop_/ ], # mixed in from POE::Loop
  },
);

# Get the list of modules
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

    # Skip modules that can't load for some reason.
    eval "require $module";
    skip "Not checking $module ...", 1 if $@;

    # Finally!
    pod_coverage_ok( $module, $opts );
  }
}
