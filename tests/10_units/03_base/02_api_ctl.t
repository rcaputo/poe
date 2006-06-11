#!perl -w

use strict;

use Test::More tests => 9;
use POE::Kernel;

use_ok('POE::API::Ctl');

# should have exported 'poectl'
ok( *poectl{CODE} == *POE::API::Ctl::poectl{CODE}, "poectl exported" );

# poectl takes 0, 1 or 2 parameters
my $rv = do { local $SIG{__WARN__} = sub { };
  poectl('one', 'two', 'three', 'four') };
ok( !defined($rv), "poectl fails when too many args used" );

is( poectl('kernel.id'), $poe_kernel->ID, "kernel.id" );

my $all = poectl();
is( ref($all), 'HASH', 'returns a hash of settings' );

# pick a key at random
my $key = (keys %$all)[rand keys(%$all)];
is( poectl($key), $all->{$key}, 'returns a single setting' );

# invalid keys
ok( !defined(poectl('this.does.not.exist')), 'non-existent key' );

# change something
poectl("testing", "testing");
is( poectl('testing'), 'testing', 'changes a setting' );

# change something locked
poectl('kernel.id', 'shouldnotwork');
is( poectl('kernel.id'), $poe_kernel->ID, "kernel.id locked" );

1;
