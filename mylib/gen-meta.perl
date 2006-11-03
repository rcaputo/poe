#!/usr/bin/perl -w
# $Id$

# Generate META.yml.

use strict;
use lib qw(./mylib);

use Module::Build;
use PoeBuildInfo qw(
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  RECOMMENDED_TIME_HIRES
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
  no_index => {
    directory => [ "mylib", "t" ]
  },
);

$build->dispatch("distmeta");

exit;
