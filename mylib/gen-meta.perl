#!/usr/bin/perl -w
# rocco // vim: ts=2 sw=2 expandtab

# Generate META.yml.

use strict;
use lib qw(./mylib);

use Module::Build;
use PoeBuildInfo qw(
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  RECOMMENDED_TIME_HIRES
  CONFIG_REQUIREMENTS
  REPOSITORY
  HOMEPAGE
);

my $build = Module::Build->new(
  dist_abstract     => DIST_ABSTRACT,
  dist_author       => DIST_AUTHOR,
  dist_name         => 'POE',
  dist_version_from => 'lib/POE.pm',
  license           => 'perl',
  recommends        => {
    RECOMMENDED_TIME_HIRES,
  },
  requires          => { CORE_REQUIREMENTS },
  build_requires    => { CONFIG_REQUIREMENTS },
  configure_requires => { CONFIG_REQUIREMENTS },
  no_index => {
    directory => [ "mylib", "t" ]
  },
  meta_merge  => {
    resources => {
       repository => REPOSITORY,
       homepage   => HOMEPAGE,
    },
  },
);

$build->dispatch("distmeta");

exit;
