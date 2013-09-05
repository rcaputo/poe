#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use warnings;
use strict;

use Test::More tests => 11;

BEGIN { $ENV{POE_CATCH_EXCEPTIONS} = 0; }

use POE;
use POE::Session;
use POE::Kernel;

our $WANT;

sub my_die {
  my( $err ) = @_;
  chomp $err;
  is( $err, $WANT, "error $WANT" );
  die "$err\nmore\n";
}

my $poe_dummy_sigdie = \&POE::Kernel::_dummy_sigdie_handler;

POE::Session->create(
  inline_states => {
    _start => sub {
      is($SIG{__DIE__}, $poe_dummy_sigdie, '_start');

      # Move to step2 with the default __DIE__ handler.
      $poe_kernel->yield( 'step2' );
    },

    #####

    step2 => sub {
      # Make sure we have the default __DIE__ at the outset.
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'step2');

      my $ret = $poe_kernel->call( $_[SESSION], 'scalar_ctx' );
      is( $ret, 42, 'scalar_ctx return value' );

      my @ret = $poe_kernel->call( $_[SESSION], 'array_ctx' );
      is_deeply( \@ret, [ 1..17 ], 'array_ctx return value' );

      # Move to step3 with a custom __DIE__ handler.
      $SIG{__DIE__} = \&my_die;
      $poe_kernel->post( $_[SESSION], 'step3' );
    },

    scalar_ctx => sub {
      # Nobody changed the default here.
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'scalar_ctx');
      return 42;
    },

    array_ctx => sub {
      # Nobody changed the default here either.
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'array_ctx');
      return ( 1..17 );
    },

    #####

    step3 => sub {
      # Make sure the globally set custom __DIE__ handler survived.
      is($SIG{__DIE__}, \&my_die, 'step3');

      my $ret = $poe_kernel->call( $_[SESSION], 'scalar_ctx3' );
      is( $ret, 42, 'scalar_ctx3 return value' );

      # Undefine SIGDIE handler to cause a hard death.
      $SIG{__DIE__} = undef;
      my @ret = $poe_kernel->call( $_[SESSION], 'array_ctx3' );
      fail( 'array_ctx3 returned unexpectedly' );
    },

    scalar_ctx3 => sub {
      # Custom handler survived call().
      is($SIG{__DIE__}, \&my_die, 'scalar_ctx3');
      return 42;
    },

    array_ctx3 => sub {
      # now we throw an execption up to our __DIE__ handler
      is($SIG{__DIE__}, undef, 'array_ctx3');
      $WANT = "array_ctx3";
      die "$WANT\nmore\n";
      return ( 1..17 );
    },
  }
);

eval { $poe_kernel->run };

# make sure we caught the execption thrown in array_ctx3
is($@, "array_ctx3\nmore\n", 'exited when expected');
