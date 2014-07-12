#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Make sure that the default behavior for POE::Wheel::FollowTail is to
# skip to the end of the file when it first starts.

use warnings;
use strict;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use IO::Handle;
use POE qw(Wheel::FollowTail Filter::Line);
use Test::More tests => 2;

my $filename = 'bingos-followtail';

# Using "!" as a newline to avoid differences in opinion about "\n".

open FH, ">$filename" or die "$!\n";
FH->autoflush(1);
print FH "moocow - this line should be skipped!";

POE::Session->create(
  package_states => [
    'main' => [qw(_start _input _error _shutdown _file_is_idle)],
  ],
  inline_states => {
    _stop => sub { undef },
  },
  heap => { filename => $filename, },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $heap->{wheel} = POE::Wheel::FollowTail->new(
    Filter      => POE::Filter::Line->new( Literal => "!" ),
    Filename    => $heap->{filename},
    InputEvent  => '_input',
    ErrorEvent  => '_error',
    IdleEvent   => '_file_is_idle',
  );

  $heap->{running} = 1;
  $heap->{counter} = 0;

  print FH "Cows go moo, yes they do!";
  close FH;
  return;
}

sub _shutdown {
  delete $_[HEAP]->{wheel};
  return;
}

sub _input {
  my ($kernel,$heap,$input) = @_[KERNEL,HEAP,ARG0];

  # Make sure we got the right line.
  is($input, 'Cows go moo, yes they do', 'Got the right line');
  ok( ++$heap->{counter} == 1, 'Cows went moo' );
  POE::Kernel->delay( _shutdown => 5 );
  return;
}

sub _error {
  my ($heap,$operation, $errnum, $errstr, $wheel_id) = @_[HEAP,ARG0..ARG3];
  diag("Wheel $wheel_id generated $operation error $errnum: $errstr\n");
  POE::Kernel->delay( _shutdown => 0.01 );
  return;
}

sub _file_is_idle {
  return unless $_[HEAP]{counter};

  # At first I thought just a delay( _shutdown => 1 ) would be nice
  # here, but there's a slight chance that the POE::Wheel::FollowTail
  # polling interval could refresh this indefinitely.
  #
  # So I took the slightly more awkward course of turning off the
  # shutdown timer and triggering shutdown immediately.

  POE::Kernel->delay(_shutdown => undef);
  POE::Kernel->yield("_shutdown");
}
