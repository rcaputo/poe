#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Tests POD for 404 links

use strict;
use Test::More;

BEGIN {
  unless (-f 'run_network_tests') {
    plan skip_all => 'Need network access (and permission) for these tests';
  }

  unless ( $ENV{RELEASE_TESTING} ) {
    plan skip_all => 'enable by setting RELEASE_TESTING';
  }

  foreach my $req (qw(Test::Pod::No404s)) {
    eval "use $req";
    if ($@) {
      plan skip_all => "$req is needed for these tests.";
    }
  }
}

all_pod_files_ok();
