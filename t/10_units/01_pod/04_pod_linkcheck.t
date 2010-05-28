#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Tests POD for invalid links

use strict;
use Test::More;

BEGIN {
  unless ( $ENV{RELEASE_TESTING} ) {
    plan skip_all => 'enable by setting RELEASE_TESTING';
  }

  foreach my $req (qw(Test::Pod::LinkCheck)) {
    eval "use $req";
    if ($@) {
      plan skip_all => "$req is needed for these tests.";
    }
  }
}

Test::Pod::LinkCheck->new->all_pod_ok;
