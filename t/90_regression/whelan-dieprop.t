#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;
use warnings;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use Test::More tests => 2;
use POE;

POE::Session->create(
  inline_states => {
    _start => sub {
      $poe_kernel->sig(DIE => 'parent_exception');
      POE::Session->create(
        inline_states => {
          _start => sub {
            $poe_kernel->sig(DIE => 'child_exception');
            $poe_kernel->yield("throw_exception");
          },
          throw_exception => sub { die "goodbye sweet world" },
          child_exception => sub { pass("child got exception") },
          _stop => sub { },
        },
      )
    },
    parent_exception => sub {
      pass("parent got exception");
      $poe_kernel->sig_handled();
    },
    _stop => sub { },
    _child => sub { },
  },
);

POE::Kernel->run();
exit;


