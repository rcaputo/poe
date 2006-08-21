#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl

# Welcome to recursive signals, this test makes sure that the signal
# bookkeeping variables are not mucked up by recursion.

use strict;

sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

use Test::More tests => 8;

# The following session checks to make sure that sig_handled on an inner
# signal doesn't make the kernel believe that the outer signal has been handled.

my $i = 0;

POE::Session->create(
  inline_states => {
    _start => sub {
      ok( ++$i == 1, "Session startup" );
      $_[KERNEL]->sig( 'HUP', 'hup' );
      $_[KERNEL]->sig( 'DIE', 'death' );
      $_[KERNEL]->signal( $_[SESSION], 'HUP' );
      $_[KERNEL]->yield( 'bad' );
    },
    bad => sub {
      fail( "We shouldn't get here" );
    },
    hup => sub {
      ok( ++$i == 2, "HUP handler" );
      my $foo = undef;
      $foo->put(); # oh my!
    },
    death => sub {
      ok( ++$i == 3, "DIE handler" );
      $_[KERNEL]->sig_handled();
    },
    _stop => sub {
      ok( ++$i == 4, "Session shutdown" );
    },
  },
);

# The following session checks to make sure that a nonmaskable signal is
# not downgraded to a terminal signal.

my $j = 0;

POE::Session->create(
  inline_states => {
    _start => sub {
      ok( ++$j == 1, "Second session startup" );
      $_[KERNEL]->sig( 'ZOMBIE', 'zombie' );
      $_[KERNEL]->sig( 'DIE', 'death' );
      $_[KERNEL]->signal( $_[SESSION], 'ZOMBIE' );
      $_[KERNEL]->yield( 'bad' );
    },
    bad => sub {
      fail( "We shouldn't get here" );
    },
    zombie => sub {
      ok( ++$j == 2, "Zombie handler" );
      $_[KERNEL]->sig_handled(); # handling this should still die
      my $foo = undef;
      $foo->put(); # oh my!
    },
    death => sub {
      ok( ++$j == 3, "DIE handler" );
      $_[KERNEL]->sig_handled();
    },
    _stop => sub {
      ok( ++$j == 4, "Second session shutdown" );
    },
  },
);


POE::Kernel->run();
