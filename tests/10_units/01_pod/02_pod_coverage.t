use Test::More;
eval "use Test::Pod::Coverage 1.00";
plan skip_all => "Test::Pod::Coverage 1.00 required for testing POD coverage" if $@;
plan skip_all => 'set POE_TEST_POD to enable this test' unless $ENV{POE_TEST_POD};

# These are the default Pod::Coverage options.
my $default_opts = { also_private => [ qr/^[A-Z0-9_]+$/, ] };

# Special case modules. Only define modules here if you want to skip ( 0 ) or 
# apply different Pod::Coverage options ( { } ).
my %special = ( 'POE' => 0,
		#'POE::Kernel' => 0,
		#'POE::Session' => 0,
		'POE::Pipe' => 0,
		'POE::Component' => 0,
		'POE::Loop' => 0,
		'POE::Resource' => 0,
		'POE::Wheel::ReadLine' => 0,
);

my @modules = all_modules();

plan tests => scalar @modules;

foreach my $module ( @modules ) {
  my $opts = $default_opts;
  if ( $module =~ /^POE::(Driver|Filter|Wheel|Queue)::/ ) {
     $opts = { also_private => [ qr/^[A-Z0-9_]+$/, ], 
	       coverage_class => 'Pod::Coverage::CountParents' };
  }
  SKIP: {
   if ( exists $special{$module} ) {
     skip "$module", 1 unless $special{$module};
     $opts = $special{$module} if ref $special{$module} eq 'HASH';
   }
   pod_coverage_ok( $module, $opts );
  }
}
