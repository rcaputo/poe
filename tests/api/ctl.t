# $Id$

use strict;

use lib qw(./mylib ../mylib ./lib ../lib ../../lib);

use Test::More tests => 15;

BEGIN { use_ok('POE'); use_ok('POE::API::Ctl'); }

use POE::API::Ctl; # to get the export

is( poectl('kernel.id'), 
    $poe_kernel->ID, 
    "equality test between kernel id control entry and actual kernel id"
  );

is( poectl('kernel.id' => 'pie'),
    $poe_kernel->ID,
    "kernel.id immutability test"
  );

is( poectl('kernel.pie' => 'tasty'),
    'tasty',
    'set a new value'
  );

is( poectl('kernel.pie'),
    'tasty',
    'get the new value',
  );


my $ctls;
eval { $ctls = poectl() };
is($@,'','no params exception check');

is(ref $ctls, 'HASH', 'data structure ref check');

foreach my $key (qw(kernel.id kernel.hostname kernel.pie)) {
    ok(defined delete $ctls->{$key}, "$key existence check");
}

is(keys %$ctls, 0, "Unknown key check");

my $ctls2;
$ctls2 = poectl();
foreach my $key (qw(kernel.id kernel.hostname kernel.pie)) {
    ok(defined delete $ctls2->{$key}, "$key existence check (verifying copy-on-get)");
}


