#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 6;

use POE::Pipe::OneWay;
use POE::Pipe::TwoWay;

### Test two-way pipe.
SKIP: {
  my ($a_rd, $a_wr, $b_rd, $b_wr) = POE::Pipe::TwoWay->new('pipe');

  skip "$^O does not support two-way pipe()", 2
    unless defined $a_rd and defined $a_wr and defined $b_rd and defined $b_wr;

  print $a_wr "a wr inet\n";
  my $b_input = <$b_rd>; chomp $b_input;
  ok(
    $b_input eq 'a wr inet',
    "two-way pipe passed data from a -> b unscathed"
  );

  print $b_wr "b wr inet\n";
  my $a_input = <$a_rd>; chomp $a_input;
  ok(
    $a_input eq 'b wr inet',
    "two-way pipe passed data from b -> a unscathed"
  );
}

### Test two-way socketpair.
SKIP: {
  my ($a_rd, $a_wr, $b_rd, $b_wr) = POE::Pipe::TwoWay->new('socketpair');

  skip "$^O does not support two-way socketpair", 2
    unless defined $a_rd and defined $a_wr and defined $b_rd and defined $b_wr;

  print $a_wr "a wr inet\n";
  my $b_input = <$b_rd>; chomp $b_input;
  ok(
    $b_input eq 'a wr inet',
    "two-way socketpair passed data from a -> b unscathed"
  );

  print $b_wr "b wr inet\n";
  my $a_input = <$a_rd>; chomp $a_input;
  ok(
    $a_input eq 'b wr inet',
    "two-way socketpair passed data from b -> a unscathed"
  );
}

### Test two-way inet sockets.
SKIP: {
  unless (-f "run_network_tests") {
    skip "Network access (and permission) required to run inet test.", 2;
  }

  my ($a_rd, $a_wr, $b_rd, $b_wr) = POE::Pipe::TwoWay->new('inet');

  skip "$^O does not support two-way inet pipes", 2
    unless defined $a_rd and defined $a_wr and defined $b_rd and defined $b_wr;

  print $a_wr "a wr inet\n";
  my $b_input = <$b_rd>; chomp $b_input;
  ok(
    $b_input eq 'a wr inet',
    "two-way inet pipe passed data from a -> b unscathed"
  );

  print $b_wr "b wr inet\n";
  my $a_input = <$a_rd>; chomp $a_input;
  ok(
    $a_input eq 'b wr inet',
    "two-way inet pipe passed data from b -> a unscathed"
  );
}

exit 0;
