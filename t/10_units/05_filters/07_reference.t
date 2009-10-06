#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Exercises Filter::Reference without the rest of POE.

use strict;
use lib qw(./mylib ../mylib);
use lib qw(t/10_units/05_filters);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use TestFilter;
use Test::More;
use Symbol qw(delete_package);

use POE::Filter::Reference;

# Determine whether we can run these tests.
BEGIN {
  local $SIG{__WARN__} = sub { };
  my $reference = eval { POE::Filter::Reference->new(); };
  if (length $@) {
    if ($@ =~ /requires Storable/) {
      plan skip_all => "These tests require Storable, FreezeThaw, or YAML.";
    }
    $@ =~ s/ at .*$//s;
    plan skip_all => $@;
  }
}

BEGIN {
  plan tests => 11 + $COUNT_FILTER_INTERFACE;
}

test_filter_interface('POE::Filter::Reference');

# A trivial, special-case serializer and reconstitutor.

sub MyFreezer::freeze {
  my $thing = shift;
  return reverse(join "\0", ref($thing), $$thing) if ref($thing) eq 'SCALAR';
  return reverse(join "\0", ref($thing), @$thing) if ref($thing) eq 'Package';
  die;
}

sub MyFreezer::thaw {
  my $thing = reverse(shift);
  my ($type, @stuff) = split /\0/, $thing;
  if ($type eq 'SCALAR') {
    my $scalar = $stuff[0];
    return \$scalar;
  }
  if ($type eq 'Package') {
    return bless \@stuff, $type;
  }
  die;
}

# Run some tests under a certain set of conditions.
sub test_freeze_and_thaw {
  my ($freezer, $compression) = @_;

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

  SKIP: {
    if (length $@) {
      $@ =~ s/[^\n]\n.*$//;
      skip $@, 1;
    }

    my $put = $filter->put( [ $scalar_ref, $object_ref ] );
    my $got = $filter->get( $put );

    $freezer = "undefined" unless defined $freezer;
    is_deeply(
      $got,
      [ $scalar_ref, $object_ref ],
      "$freezer successfully froze and thawed"
    );
  }
}

# Test each combination of things.
test_freeze_and_thaw(undef,            undef);
test_freeze_and_thaw(undef,            9    );
test_freeze_and_thaw('MyFreezer',      undef);
test_freeze_and_thaw('MyFreezer',      9    );
test_freeze_and_thaw('MyOtherFreezer', undef);
test_freeze_and_thaw('MyOtherFreezer', 9    );

my $freezer = MyOtherFreezer->new();

test_freeze_and_thaw($freezer,         undef);
test_freeze_and_thaw($freezer,         9    );

# Test get_pending.

my $pending_filter = POE::Filter::Reference->new();
my $frozen_thing   = $pending_filter->put( [ [ 2, 4, 6 ] ] );
$pending_filter->get_one_start($frozen_thing);
my $pending_thing  = $pending_filter->get($pending_filter->get_pending());

is_deeply(
  $pending_thing, [ [ 2, 4, 6 ], [ 2, 4, 6 ] ],
  "filter reports proper pending data"
);

# Drop MyOtherFreezer from the symbol table.

delete_package('MyOtherFreezer');

# Create some "pretend" entries in the symbol table, to ensure that
# POE::Filter::Reference loads the entire module if all needed methods
# are not present.
eval q{
  sub never_called {
    return MyOtherFreezer::thaw(MyOtherFreezer::freeze(@_));
  }
};
die if $@;

# Test each combination of things.
test_freeze_and_thaw('MyOtherFreezer', undef);
test_freeze_and_thaw('MyOtherFreezer', 9    );

exit;
