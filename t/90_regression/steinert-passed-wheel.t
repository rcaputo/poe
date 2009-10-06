#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Passing a POE::Wheel or something into an event handler will cause
# that thing's destruction to be delayed until outside the session's
# event handler.  The result is a hard error.

use strict;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use POE;
use POE::Wheel::ReadWrite;
use POE::Pipe::OneWay;

use Test::More tests => 1;

POE::Session->create(
  inline_states => {
    _start    => \&setup,
    got_input => sub { },
    destructo => \&die_die_die,
    _stop     => \&shutdown,
  }
);

POE::Kernel->run();
exit;

sub setup {
  my ($r, $w) = POE::Pipe::OneWay->new();
  my $wheel = POE::Wheel::ReadWrite->new(
    InputHandle => $r,
    OutputHandle => $w,
    InputEvent   => "got_input",
  );
  $_[KERNEL]->yield(destructo => $wheel);
  return;
}

sub die_die_die {
  return @_;  # What the heck, return it too just for perversity.
}

sub shutdown {
  pass("normal shutdown");
}
