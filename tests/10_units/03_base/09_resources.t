#!/usr/bin/perl

use strict;

use Test::More tests => 7;

use_ok('POE::Resources');

{
  my $failure_happened;
  my %requires;
  local *CORE::GLOBAL::require = sub {
    my $name = shift;
    my ($resource) = $name =~ m{Resource(?:/|::)(\w+)};
    my $xs = $name =~ m{(?:/|::)XS(?:/|::)};
    
    # a state machine
    my $state = $requires{$resource};
    my $visible_state = $state || "undef";
    $requires{$resource} = "test bug: no new state! (from: $visible_state)";
    unless (defined $state) {
      # should be looking for XS version first
      if ($xs) {
        if (keys(%requires) % 2) {
          $requires{$resource} = "use non XS";
          die "Can't locate $name in \@INC (this is a fake error)\n";
        } else {
          $requires{$resource} = "ok: using XS";
        }
      } else {
        # woops! a bug!
        $requires{$resource} = "bug: XS load wasn't first: $name";
      }
    } elsif ($state eq 'use non XS') {
      if (not $xs) {
        $requires{$resource} = "ok: using non XS";

        # test that errors propagate out of initialize properly
        if (keys(%requires) > 6) {
          $failure_happened = "happened";
          die "Can't locate $name in \@INC (this is a fake error #2)\n";
        }
      } else {
        $requires{$resource} = "bug: multiple XS loads";
      }
    }
  };

  eval {
    POE::Resources->initialize();
  };
  if ($@ =~ /fake error #2/) {
    $failure_happened = "seen";
  } elsif ($@) { die $@ }

  # analyse the final state and produce test results
  my @requires = map [$_, $requires{$_}], keys %requires;

  ok( 0 < grep($_->[1] =~ /^ok: using XS/, @requires),
    "can use XS versions" );
  ok( 0 < grep($_->[1] =~ /^ok: using non XS/, @requires),
    "can use non-XS versions" );
  {
    my @fails = grep($_->[1] !~ /^ok:/, @requires);
    diag("$_->[0]: $_->[1]") for @fails;
    ok( 0 == @fails, "all module loads successful" );
  }
  SKIP: {
    skip "Resources didn't try to load enough resources to trigger this test",
      1 unless defined $failure_happened;
    is( $failure_happened, 'seen', 'initialized rethrows loading errors');
  }

}

{
  my $failure_happened;
  local *CORE::GLOBAL::require = sub {
    unless (defined $failure_happened) {
      $failure_happened = "happened";
      die "really bad error (this is fake error #3)\n";
    } else {
      $failure_happened = "require called more than once!";
    }
  };

  eval {
    POE::Resources->initialize();
  };
  if ($@ =~ /fake error #3/) {
    $failure_happened = "seen";
  } elsif ($@) { die $@ }

  ok( defined $failure_happened, 'initialize ran and encountered error' );
  is( $failure_happened, 'seen', 'caught error' );
}

exit 0;
