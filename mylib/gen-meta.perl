#!/usr/bin/perl -w
# $Id$

# Generate META.yml.

use strict;
use lib qw(./mylib);

use Module::Build;
use PoeBuildInfo qw(
  $dist_abstract
  $dist_author
  %core_requirements
  %recommended_time_hires
);

my $build = Module::Build->new(
  dist_abstract     => $dist_abstract,
  dist_author       => $dist_author,
  dist_name         => 'POE',
  dist_version_from => 'lib/POE.pm',
  license           => 'perl',
  recommends        => {
    %recommended_time_hires,
  },
  requires          => \%core_requirements,
);

$build->dispatch("distmeta");

exit;
