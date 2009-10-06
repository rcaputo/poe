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

print "1..10\n";

my $test = 0;

POE::Session->create(
  inline_states => {
    _start => sub {
      $test++;
      print "not " unless $test == 1;
      print "ok $test # starting parent\n";

      $_[KERNEL]->yield('parent');
    },

    _stop => sub {
      $test++;
      print "not " unless $test == 8;
      print "ok $test # stopping parent\n";
    },

    _parent => sub {
      $test++;
      print "not ok $test # parent received _parent\n";
    },

    _child => sub {

      $test++;
      if ($test == 4) {
        print "not " unless (
          $_[ARG1]->ID == 3 and
          $_[ARG0] eq "create"
        );
        print "ok $test # parent should receive _child create\n";
        return;
      }

      if ($test == 6) {
        print "not " unless (
          $_[ARG1]->ID == 3 and
          $_[ARG0] eq "lose"
        );
        print "ok $test # parent should receive _child lose\n";
        return;
      }

      print "not ok $test # parent received _child $_[ARG0]\n";
    },

    parent => sub {
      $test++;
      print "not " unless $test == 2;
      print "ok $test # parent spawning child\n";

      POE::Session->create(
        inline_states => {
          _start => sub {
            $test++;
            print "not " unless $test == 3;
            print "ok $test # child starting\n";

            $_[KERNEL]->yield('child');
          },

          _stop => sub {
            $test++;
            print "not " unless $test == 10;
            print "ok $test # child stopping\n";
          },

          _parent => sub {
            $test++;
            if ($test == 7) {
              print "not " unless (
                $_[ARG0]->ID == 2 and
                $_[ARG1]->isa("POE::Kernel")
              );
              print "ok $test # child should receive _parent = kernel\n";
              return;
            }

            print "not ok $test # child given to $_[ARG1]\n";
          },

          _child => sub {
            $test++;
            print "not ok $test # child received _child $_[ARG0]\n";
          },

          child => sub {
            $test++;
            print "not " unless $test == 5;
            print "ok $test # child detaching itself\n";

            $_[KERNEL]->detach_myself;
            $_[KERNEL]->yield("done");
          },

          done => sub {
            $test++;
            print "not " unless $test == 9;
            print "ok $test # child is done\n";
          },
        }
      );
    } # parent
  } # inline_states
);

$poe_kernel->run;
