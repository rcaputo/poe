#!/usr/bin/env perl
# set ts=2 sw=2 expandtab filetype=perl

# Ensure that _start and _stop handlers return values as documented.

use warnings;
use strict;

use Test::More tests => 1;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

my @results;

{
  package Fubar;

  use POE;

  sub new {
    my ($class) = @_;
    my $self = {};
    bless $self, $class;
    return $self;
  }

  sub createsession {
    my $self = shift;
    POE::Session->create(object_states => [$self => [qw( _start _stop )]]);
  }

  sub _start {
    return '_start';
  }

  sub _stop {
    return '_stop';
  }
}

POE::Session->create(
  inline_states => {
    _start => sub {
      Fubar->new()->createsession();
    },
    _child => sub {
      push @results, [ $_[ARG0], $_[ARG2] ];
    },
    _stop => sub { undef },
  }
);

$poe_kernel->run;

is_deeply(
  \@results, [
    [qw( create _start ) ],
    [qw( lose _stop ) ],
  ]
);
