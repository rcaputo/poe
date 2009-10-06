#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use POE qw(Wheel::FollowTail);
use Test::More tests => 1;

my $filename = 'bingos-followtail';

open FH, "> $filename" or die "$!\n";

POE::Session->create(
  package_states => [
        'main' => [qw(_start _input _error _shutdown)],
  ],
  heap => { filename => $filename, },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $heap->{wheel} = POE::Wheel::FollowTail->new(
        Filename     => $heap->{filename},
        InputEvent   => '_input',
        ErrorEvent   => '_error',
  );
  $heap->{counter} = 0;
  print FH "Cows go moo, yes they do\n";
  close FH;
  return;
}

sub _shutdown {
  delete $_[HEAP]->{wheel};
  return;
}

sub _input {
  my ($kernel,$heap,$input) = @_[KERNEL,HEAP,ARG0];
  $heap->{counter}++;
  ok( $heap->{counter} == 1, 'Cows went moo' );
  $kernel->delay( '_shutdown', 5 ); # Wait five seconds.
  return;
}

sub _error {
  my ($heap,$operation, $errnum, $errstr, $wheel_id) = @_[HEAP,ARG0..ARG3];
  diag("Wheel $wheel_id generated $operation error $errnum: $errstr\n");
  delete $heap->{wheel};
  return;
}

