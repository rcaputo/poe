#!/usr/bin/perl -w
# $Id$

# Exercises Filter::Reference without the rest of POE.

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE::Filter::Reference;
use Symbol qw(delete_package);

use TestSetup;

# Determine whether we can run these tests.
{ local $SIG{__WARN__} = sub { };
  my $reference = eval { POE::Filter::Reference->new(); };
  if (length $@) {
    &test_setup(
      0,
      "Storable, FreezeThaw, or YAML is required for these tests."
    ) if $@ =~ /requires Storable/;
    $@ =~ s/ at .*$//s;
    &test_setup(0, $@);
    exit;
  }
}

# A trivial, special-case serializer and reconstitutor.

sub MyFreezer::freeze {
  my $thing = shift;
  if (ref($thing) eq 'SCALAR') {
    return reverse(join "\0", ref($thing), $$thing);
  }
  elsif (ref($thing) eq 'Package') {
    return reverse(join "\0", ref($thing), @$thing);
  }
  die;
}

sub MyFreezer::thaw {
  my $thing = reverse(shift);
  my ($type, @stuff) = split /\0/, $thing;
  if ($type eq 'SCALAR') {
    my $scalar = $stuff[0];
    return \$scalar;
  }
  elsif ($type eq 'Package') {
    return bless \@stuff, $type;
  }
  die;
}

# Start our engines.
&test_setup(109);

# Run some tests under a certain set of conditions.
sub test_freeze_and_thaw {
  my ($test_number, $freezer, $compression) = @_;

  my $scalar     = 'this is a test';
  my $scalar_ref = \$scalar;
  my $object_ref = bless [ 1, 1, 2, 3, 5 ], 'Package';

  my $filter;
  eval {
    # Hide warnings.
    local $SIG{__WARN__} = sub { };
    $filter = POE::Filter::Reference->new( $freezer, $compression );
    die "filter not created with freezer=$freezer" unless $filter;
  };

  if (length $@) {
    $@ =~ s/[^\n]\n.*$//;
    &many_not_ok($test_number, $test_number + 9, $@);
    return;
  }

  my $put = $filter->put( [ $scalar_ref, $object_ref ] );
  my $got = $filter->get( $put );

  if (@$got == 2) {
    &ok($test_number);

    if (ref($got->[0]) eq 'SCALAR') {
      &ok($test_number + 1);
      &ok_if($test_number + 2, ${$got->[0]} eq $scalar);
    }
    else {
      &many_not_ok($test_number + 1, $test_number + 2);
    }

    if (ref($got->[1]) eq 'Package') {
      &ok($test_number + 3);

      if (@{$got->[1]} == 5) {
        &ok($test_number + 4);
        &ok_if($test_number + 5, $got->[1]->[0] == 1);
        &ok_if($test_number + 6, $got->[1]->[1] == 1);
        &ok_if($test_number + 7, $got->[1]->[2] == 2);
        &ok_if($test_number + 8, $got->[1]->[3] == 3);
        &ok_if($test_number + 9, $got->[1]->[4] == 5);
      }
      else {
        &many_not_ok( $test_number + 4, $test_number + 9);
      }
    }
    else {
      &many_not_ok($test_number + 3, $test_number + 9);
    }
  }
  else {
    &many_not_ok($test_number, $test_number + 9);
  }
}

# Test each combination of things.
&test_freeze_and_thaw(  1, undef,            undef );
&test_freeze_and_thaw( 11, undef,            9     );
&test_freeze_and_thaw( 21, 'MyFreezer',      undef );
&test_freeze_and_thaw( 31, 'MyFreezer',      9     );
&test_freeze_and_thaw( 41, 'MyOtherFreezer', undef );
&test_freeze_and_thaw( 51, 'MyOtherFreezer', 9     );

my $freezer = MyOtherFreezer->new();

&test_freeze_and_thaw( 61, $freezer,         undef );
&test_freeze_and_thaw( 71, $freezer,         9     );

# Test get_pending.

my $pending_filter = POE::Filter::Reference->new();
my $frozen_thing   = $pending_filter->put( [ [ 2, 4, 6 ] ] );
$pending_filter->get_one_start($frozen_thing);
my $pending_thing  = $pending_filter->get($pending_filter->get_pending());

&ok_if( 81, @$pending_thing          == 2 );
&ok_if( 82, @{$pending_thing->[0]}   == 3 );
&ok_if( 83, @{$pending_thing->[1]}   == 3 );

&ok_if( 84, $pending_thing->[0]->[0] == 2 );
&ok_if( 85, $pending_thing->[0]->[1] == 4 );
&ok_if( 86, $pending_thing->[0]->[2] == 6 );

&ok_if( 87, $pending_thing->[1]->[0] == 2 );
&ok_if( 88, $pending_thing->[1]->[1] == 4 );
&ok_if( 89, $pending_thing->[1]->[2] == 6 );

# Throw away MyOtherFrezere's methods to make it look like it's only
# partly loaded.  This will should fool POE::Filter::Reference::new().

delete_package("MyOtherFreezer");

# Test each combination of things.
&test_freeze_and_thaw( 90,  'MyOtherFreezer',            undef );
&test_freeze_and_thaw( 100, 'MyOtherFreezer',            9     );

&results();

exit;
