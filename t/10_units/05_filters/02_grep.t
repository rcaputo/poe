#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Exercises Filter::Grep without POE

use strict;
use lib qw(./mylib ../mylib);
use lib qw(t/10_units/05_filters);

use Data::Dumper; $Data::Dumper::Indent=1;

use TestFilter;
use Test::More tests => 26 + $COUNT_FILTER_INTERFACE + 2*$COUNT_FILTER_STANDARD;

use_ok("POE::Filter::Grep");
test_filter_interface("POE::Filter::Grep");

# Test erroneous new() args
test_new("No Args");
test_new("even", "one", "two", "odd");
test_new("Non code CODE ref", Code => [ ]);
test_new("Single Get ref", Get => sub { });
test_new("Single Put ref", Put => sub { });
test_new("Non CODE Get",   Get => [ ], Put => sub { });
test_new("Non CODE Put",   Get => sub { }, Put => [ ]);

sub test_new {
    my $name = shift;
    my @args = @_;
    my $filter;
    eval { $filter = POE::Filter::Grep->new(@args); };
    ok(!(!$@), $name);
}

# Test actual mapping of Get, Put, and Code
{ # Test Get and Put
  my $filter = POE::Filter::Grep->new(
    Get => sub { /\d/ },
    Put => sub { /[a-zA-Z]/ }
  );
  is_deeply($filter->put([qw/A B C 1 2 3/]), [qw/A B C/], "Test Put");
  is_deeply($filter->get([qw/a b c 1 2 3/]), [qw/1 2 3/], "Test Get");

  test_filter_standard(
    $filter,
    [qw/a b c 1 2 3/],
    [qw/1 2 3/],
    [qw//],
  );
}

{ # Test Code
  my $filter = POE::Filter::Grep->new(Code => sub { /(\w)/ });
  is_deeply($filter->put([qw/a b c 1 2 3 ! @ /]), [qw/a b c 1 2 3/],
    "Test Put (as Code)");
  is_deeply($filter->get([qw/a b c 1 2 3 ! @ /]), [qw/a b c 1 2 3/],
    "Test Get (as Code)");

  test_filter_standard(
    $filter,
    [qw/a b c 1 2 3 ! @/],
    [qw/a b c 1 2 3/],
    [qw/a b c 1 2 3/],
  );
}

{
  my $filter = POE::Filter::Grep->new( Get => sub { /1/ }, Put => sub { /1/ } );

  # Test erroneous modification
  test_modify("Modify Get not CODE ref",  $filter, Get => [ ]);
  test_modify("Modify Put not CODE ref",  $filter, Put => [ ]);
  test_modify("Modify Code not CODE ref", $filter, Code => [ ]);
  test_modify("Modify with invalid key", $filter, Elephant => sub { });
  
  sub test_modify {
    my ($name, $filter, @args) = @_;
    local $SIG{__WARN__} = sub { };
    eval { $filter->modify(@args); };
    ok(defined $@, $name);
  }

  $filter->modify(Get => sub { /\d/ });
  is_deeply($filter->get([qw/a b c 1 2 3/]), [qw/1 2 3/], "Modify Get");

  $filter->modify(Put => sub { /[a-zA-Z]/ });
  is_deeply($filter->put([qw/A B C 1 2 3/]), [qw/A B C/], "Modify Put");

  $filter->modify(Code => sub { /(\w)/ });
  is_deeply($filter->put([qw/a b c 1 2 3 ! @ /]), [qw/a b c 1 2 3/], "Modify Put (as Code)");
  is_deeply($filter->get([qw/a b c 1 2 3 ! @ /]), [qw/a b c 1 2 3/], "Modify Get (as Code)");
}

# Grep (from stackable's tests) -- testing get_pending
{
  my @test_list = (1, 1, 2, 3, 5);
  my $grep = POE::Filter::Grep->new( Code => sub { $_ & 1 } );
  $grep->get_one_start( [ @test_list ] );

  my $grep_pending = join '', @{$grep->get_pending()};
  ok($grep_pending eq '11235', "grep filter's parser buffer verifies");

  foreach my $compare (@test_list) {
    next unless $compare & 1;
    my $next = $grep->get_one();
    is_deeply($next, [ $compare ], "grep filter get_one() returns [$compare]");
  }

  my $grep_next = $grep->get_one();
  ok(!@$grep_next, "nothing left to get from grep filter");
}
