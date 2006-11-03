# $Id$

use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 27;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

BEGIN { use_ok('POE'); use_ok('POE::Resource::Controls'); }

eval { $poe_kernel->_data_magic_initialize; };
is($@,'', "_data_magic_initialize exception check");

is( $poe_kernel->_data_magic_get('kernel.id'),
    $poe_kernel->ID,
    "equality test between kernel id control entry and actual kernel id"
  );

is( $poe_kernel->_data_magic_set('kernel.id' => 'pie'),
    $poe_kernel->ID,
    "kernel.id immutability test"
  );

is( $poe_kernel->_data_magic_set('kernel.pie' => 'tasty'),
    'tasty',
    'set a new value'
  );

is( $poe_kernel->_data_magic_get('kernel.pie'),
    'tasty',
    'get the new value',
  );


is( $poe_kernel->_data_magic_lock('kernel.pie'),
    undef,
    'lock source protection',
  );

is( $poe_kernel->_data_magic_unlock('kernel.pie'),
    undef,
    'unlock source protection',
  );

eval { $poe_kernel->_data_magic_set() };
ok(
  $@ && $@ =~ /_data_magic_set needs two parameters/,
  "exception on bad _data_magic_set() call"
);

is( $poe_kernel->_data_magic_get("nonexistent"),
  undef,
  '_data_magic_get returns undef for noexistent magic'
);

package POE::Magic::Test;

use POE;
use Test::More;

is( $poe_kernel->_data_magic_lock('kernel.pie'),
    1,
    'lock',
  );

is( $poe_kernel->_data_magic_set('kernel.pie' => 'yucky'),
    'tasty',
    'check lock immutability'
  );


is( $poe_kernel->_data_magic_unlock('kernel.pie'),
    1,
    'unlock',
  );


is( $poe_kernel->_data_magic_set('kernel.pie' => 'yucky'),
    'yucky',
    'check unlock mutability'
  );


my $ctls;
eval { $ctls = $poe_kernel->_data_magic_get() };
is($@,'','_data_magic_get with no params exception check');

is(ref $ctls, 'HASH', 'data structure ref check');

foreach my $key (qw(kernel.id kernel.hostname kernel.pie)) {
    ok(defined delete $ctls->{$key}, "$key existence check");
}

is(keys %$ctls, 0, "Unknown key check");

my $ctls2;
$ctls2 = $poe_kernel->_data_magic_get();
foreach my $key (qw(kernel.id kernel.hostname kernel.pie)) {
    ok(defined delete $ctls2->{$key}, "$key existence check (verifying copy-on-get)");
}

eval { $poe_kernel->_data_magic_lock() };
ok(
  $@ && $@ =~ /_data_magic_lock needs one parameter/,
  "exception on bad _data_magic_lock() call"
);

eval { $poe_kernel->_data_magic_unlock() };
ok(
  $@ && $@ =~ /_data_magic_unlock needs one parameter/,
  "exception on bad _data_magic_unlock() call"
);

is( $poe_kernel->_data_magic_finalize(),
  1,
  "POE::Resource::Controls finalized ok"
);

1;
