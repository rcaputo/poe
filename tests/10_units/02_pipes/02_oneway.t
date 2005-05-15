#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;

use POE::Pipe::OneWay;
use POE::Pipe::TwoWay;

### Test one-way pipe() pipe.

SKIP: {
  my ($uni_read, $uni_write) = POE::Pipe::OneWay->new('pipe');
  skip "$^O does not support one-way pipe()", 1
    unless defined $uni_read and defined $uni_write;

  print $uni_write "whee pipe\n";
  my $uni_input = <$uni_read>; chomp $uni_input;
  ok($uni_input eq "whee pipe", "one-way pipe passed data unscathed");
}

### Test one-way socketpair() pipe.
SKIP: {
  my ($uni_read, $uni_write) = POE::Pipe::OneWay->new('socketpair');

  skip "$^O does not support one-way socketpair()", 1
    unless defined $uni_read and defined $uni_write;

  print $uni_write "whee socketpair\n";
  my $uni_input = <$uni_read>; chomp $uni_input;
  ok(
    $uni_input eq 'whee socketpair',
    "one-way socketpair passed data unscathed"
  );
}

### Test one-way pair of inet sockets.
SKIP: {
  my ($uni_read, $uni_write) = POE::Pipe::OneWay->new('inet');
  skip "$^O does not support one-way inet sockets.", 1
    unless defined $uni_read and defined $uni_write;

  print $uni_write "whee inet\n";
  my $uni_input = <$uni_read>; chomp $uni_input;
  ok(
    $uni_input eq 'whee inet',
    "one-way inet pipe passed data unscathed"
  );
}

exit 0;
