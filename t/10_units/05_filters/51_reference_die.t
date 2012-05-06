#!/usr/bin/perl
# vim: ts=2 sw=2 expandtab

use warnings;
use strict;

use POE::Filter::Reference;
use Test::More;

BEGIN {
  eval 'use YAML';
  if ($@) {
    plan skip_all => 'YAML module not available';
  }
  else {
    plan tests => 5;
  }
}

# Create a YAML stream a la Perl.
# Baseline.  Verify the basic YAML is liked.

my $test_data = {
  test => 1,
  foo  => [1, 2],
  bar  => int(rand(999)),
};

my $basic_yaml = YAML::Dump($test_data);

# Baseline test.  Make sure the Perl YAML can be decoded.

ok(
  doesnt_die($basic_yaml),
  "basic yaml doesn't die"
);

# Some YAML producers don't include newlines.
# This reportedly causes problems for Perl's YAML parser.

{
  my $no_newline_yaml = $basic_yaml;
  chomp $no_newline_yaml;

  ok(
    dies_when_allowed($no_newline_yaml),
    "yaml without newlines dies when allowed"
  );

  ok(
    exception_caught($no_newline_yaml),
    "yaml without newlines returns error when caught"
  );
}

# YAML supports a "...\n" record terminator.
# Perl's YAML is reported to dislike this.

{
  my $terminated_yaml = $basic_yaml . "...\n";

  ok(
    dies_when_allowed($terminated_yaml),
    "terminated_yaml dies when allowed"
  );

  ok(
    exception_caught($terminated_yaml),
    "terminated_yaml returns error when caught"
  );
}

exit;

sub doesnt_die {
  my $yaml = shift();

  my $pfr     = POE::Filter::Reference->new('YAML', 0, 0);
  my $encoded = length($yaml) . "\0" . $yaml;

  my $decoded = $pfr->get([ $encoded ]);

  return(
    defined($decoded)             &&
    (ref($decoded) eq 'ARRAY')    &&
    (@$decoded == 1)              &&
    (ref($decoded->[0]) eq 'HASH')
  );
}

sub dies_when_allowed {
  my $yaml = shift();

  my $pfr     = POE::Filter::Reference->new('YAML', 0, 0);
  my $encoded = length($yaml) . "\0" . $yaml;

  $@ = undef;
  my $decoded = eval { $pfr->get([ $encoded ]); };

  return !!$@;
}

sub exception_caught {
  my $yaml = shift();

  my $pfr     = POE::Filter::Reference->new('YAML', 0, 1);
  my $encoded = length($yaml) . "\0" . $yaml;

  my $decoded = eval { $pfr->get([ $encoded ]); };

  return(
    defined($decoded)             &&
    (ref($decoded) eq 'ARRAY')    &&
    (@$decoded == 1)              &&
    (ref($decoded->[0]) eq '')
  );
}
