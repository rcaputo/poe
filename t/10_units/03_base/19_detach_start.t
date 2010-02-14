# vim: ts=2 sw=2 sts=2 ft=perl expandtab
use strict;

$| = 1;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use Test::More tests => 14;
use POE;

my $seq          = 0;
my $_child_fired = 0;

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->alias_set('Parent');
      is(++$seq, 1, "_start Parent");
      POE::Session->create(
        inline_states => {
          _start => sub {
            $_[KERNEL]->alias_set('Child');
            is(++$seq, 2, "_start Child");
          },
          _stop => sub {
            is(++$seq, 6, "_stop Child");
          },
        },
      );
      POE::Session->create(
        inline_states => {
          _start => sub {
            $_[KERNEL]->alias_set('Detached');
            is(++$seq, 4, "_start Detached");
            #diag "Detaching session 'Detached' from its parent";
            $_[KERNEL]->detach_myself;
          },
          _parent => sub {
            is(++$seq, 5, "_parent Detached");
            ok($_[ARG1]->isa("POE::Kernel"), "child parent is POE::Kernel");
          },
          _stop => sub {
            $seq++;
            ok($seq == 8 || $seq == 9, "_stop Detached");
          },
        },
      );
    },
    _child => sub {
      $seq++;
      ok($seq == 3 || $seq == 7, "_child Parent");
      $_child_fired++;
      ok(
        $_[KERNEL]->alias_list($_[ARG1]) ne 'Detached',
        "$_[STATE]($_[ARG0]) fired for " . $_[KERNEL]->alias_list($_[ARG1]->ID)
      );
    },
    _stop => sub {
      $seq++;
      ok($seq == 8 || $seq == 9, "_stop Parent");
    },
  },
);

POE::Kernel->run();

pass "_child not fired for session detached in _start" unless (
  $_child_fired != 2
);
pass "Stopped";
