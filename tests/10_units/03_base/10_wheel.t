#!/usr/bin/perl -w

use strict;

use Test::More tests => 7;

BEGIN { use_ok("POE::Wheel") }

eval { my $x = POE::Wheel->new() };
ok(
  $@ && $@ =~ /not meant to be used directly/,
  "don't instantiate POE::Wheel"
);

my $id = POE::Wheel::allocate_wheel_id();
ok($id == 1, "first wheel ID == 1");

POE::Wheel::_test_set_wheel_id(0);
my $new_id = POE::Wheel::allocate_wheel_id();
ok($new_id == 2, "second wheel ID == 1");

my $old_id = POE::Wheel::free_wheel_id($id);
ok($old_id == 1, "removed first wheel id");

POE::Wheel::_test_set_wheel_id(0);
my $third = POE::Wheel::allocate_wheel_id();
ok($third == 1, "third wheel reclaims unused ID 1");

POE::Wheel::_test_set_wheel_id(0);
my $fourth = POE::Wheel::allocate_wheel_id();
ok($fourth == 3, "fourth wheel ID == 3");

exit 0;
