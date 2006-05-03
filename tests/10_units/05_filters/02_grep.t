#!/usr/bin/perl -w
# $Id$
# Exercises Filter::Grep without POE

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);
use Data::Dumper; $Data::Dumper::Indent=1;
use POE::Filter::Grep;
use Test::More tests => 17; # FILL ME IN

# Test erroneous new() args
test_new("No Args");
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
    ok(defined $@, $name);
}

my $filter;
# Test actual mapping of Get, Put, and Code
$filter = POE::Filter::Grep->new( Get => sub { /\d/ }, Put => sub { /[a-zA-Z]/ } );
is_deeply($filter->put([qw/A B C 1 2 3/]), [qw/A B C/], "Test Put");
is_deeply($filter->get([qw/a b c 1 2 3/]), [qw/1 2 3/], "Test Get");

$filter = POE::Filter::Grep->new(Code => sub { /(\w)/ });
is_deeply($filter->put([qw/a b c 1 2 3 ! @ /]), [qw/a b c 1 2 3/], "Test Put (as Code)");
is_deeply($filter->get([qw/a b c 1 2 3 ! @ /]), [qw/a b c 1 2 3/], "Test Get (as Code)");



$filter = POE::Filter::Grep->new( Get => sub { /1/ }, Put => sub { /1/ } );
# Test erroneous modification
test_modify("Modify Get not CODE ref",  $filter, Get => [ ]);
test_modify("Modify Put not CODE ref",  $filter, Put => [ ]);
test_modify("Modify Code not CODE ref", $filter, Code => [ ]);

sub test_modify {
   my ($name, $filter, @args) = @_;
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
