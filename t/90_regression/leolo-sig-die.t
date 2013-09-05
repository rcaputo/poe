#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use warnings;
use strict;

use Test::More tests => 12;

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
      $poe_kernel->yield( 'step2' );
    },

    #####

    step2 => sub {
      # make sure we have a reset __DIE__ in yield
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'step2');
      my $ret = $poe_kernel->call( $_[SESSION], 'scalar_ctx' );
      is( $ret, 42, 'ret' );
      my @ret = $poe_kernel->call( $_[SESSION], 'array_ctx' );
      is_deeply( \@ret, [ 1..17 ], 'ret' );


      $SIG{__DIE__} = \&my_die;
      $poe_kernel->post( $_[SESSION], 'step3' );
    },

    scalar_ctx => sub {
      # Allow global __DIE__.
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'scalar_ctx');
      return 42;
    },

    array_ctx => sub {
      # make sure we have a reset __DIE__ in call to array context
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'array_ctx');
      return ( 1..17 );
    },

    #####

    step3 => sub {
      # make sure we have a reset __DIE__ in a post
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'step3');
      my $ret = $poe_kernel->call( $_[SESSION], 'scalar_ctx3' );
      is( $ret, 42, 'ret' );
      my @ret = $poe_kernel->call( $_[SESSION], 'array_ctx3' );
      fail( 'we never get here' );
    },

    scalar_ctx3 => sub {
      # make sure we have a reset __DIE__ even if we set one
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'scalar_ctx3');
      return 42;
    },

    array_ctx3 => sub {
      # now we throw an execption up to our __DIE__ handler
      is($SIG{__DIE__}, $poe_dummy_sigdie, 'array_ctx');
      $WANT = "array_ctx3";
      die "$WANT\n";
      return ( 1..17 );
    },
  }
);

eval { $poe_kernel->run };

# make sure we caught the execption thrown in array_ctx3
is($@, "array_ctx3\nmore\n", 'exited');
