#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl


# System shouldn't fail in this case.

use strict;

sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;

use constant TESTS => 4;
use Test::More tests => TESTS;

my $command = "/bin/true";

SKIP: {
  my @commands = grep { -x } qw(/bin/true /usr/bin/true);
  skip( "Couldn't find a 'true' to run under system()", TESTS ) unless (
    @commands
  );

  my $command = shift @commands;

  diag( "Using '$command' as our thing to run under system()" );

  my $caught_child = 0;

  POE::Session->create(
    inline_states => {
      _start => sub {
				my $sig_chld = $SIG{CHLD};
				$sig_chld = "(undef)" unless defined $sig_chld;

        is(
          system( $command ), 0,
          "System returns properly chld($sig_chld) err($!)"
        );
        $! = undef;

        $_[KERNEL]->sig( 'CHLD', 'chld' );
        is(
          system( $command ), 0,
          "System returns properly chld($sig_chld) err($!)"
        );
        $! = undef;

        $_[KERNEL]->sig( 'CHLD' );
        is(
          system( $command ), 0,
          "System returns properly chld($sig_chld) err($!)"
        );
        $! = undef;
      },
      chld => sub {
        diag( "Caught child" );
        $caught_child++;
      },
    }
  );

  is( $caught_child, 0, "no child procs caught" );
}

POE::Kernel->run();
