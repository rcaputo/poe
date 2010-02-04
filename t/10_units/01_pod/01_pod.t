# vim: ts=2 sw=2 filetype=perl expandtab

use Test::More;

unless ( $ENV{RELEASE_TESTING} ) {
  plan skip_all => 'enable by setting RELEASE_TESTING';
}

eval "use Test::Pod 1.00";
plan skip_all => "Test::Pod 1.00 required for testing POD" if $@;
all_pod_files_ok();
