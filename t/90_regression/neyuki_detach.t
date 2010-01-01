#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use lib qw(./mylib ../mylib);

$| = 1;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use POE;
use Test::More tests => 12;

my $seq = 0;

POE::Session->create(
  inline_states => {
    _start => sub {
      is(++$seq, 1, "starting parent in sequence");
      $_[KERNEL]->yield('parent');
    },

    _stop => sub {
      is(++$seq, 9, "stopping parent in sequence");
    },

    _parent => sub {
      fail("parent received unexpected _parent");
    },

    _child => sub {
      if ($_[ARG0] eq "create") {
        is(++$seq, 4, "parent received _child create in sequence");
        return;
      }

      if ($_[ARG0] eq "lose") {
        is(++$seq, 6, "parent received _child lose in sequence");
        return;
      }

      fail("parent received unexpected _child $_[ARG0]");
    },

    done => sub {
      is(++$seq, 8, "parent done in sequence");
    },

    parent => sub {
      is(++$seq, 2, "parent spawning child in sequence");

      POE::Session->create(
        inline_states => {
          _start => sub {
            is(++$seq, 3, "child started in sequence");
            $_[KERNEL]->yield('child');
          },

          _stop => sub {
            is(++$seq, 11, "child stopped in sequence");
          },

          _parent => sub {
            is(++$seq, 7, "child received _parent in sequence");
            ok($_[ARG1]->isa("POE::Kernel"), "child parent is POE::Kernel");
          },

          _child => sub {
            fail("child received unexpected _child");
          },

          child => sub {
            is(++$seq, 5, "child detached itself in sequence");

            $_[KERNEL]->detach_myself;
            $_[KERNEL]->yield("done");
          },

          done => sub {
            is(++$seq, 10, "child is done in sequence");
          },
        }
      );

      $_[KERNEL]->yield("done");
    } # parent
  } # inline_states
);

POE::Kernel->run();
