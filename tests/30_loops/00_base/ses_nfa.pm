#!/usr/bin/perl -w
# $Id$

# Tests NFA sessions.

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);
use TestSetup;
&test_setup(20);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw(NFA);

### Plain NFA.  This simulates a pushbutton that toggles a light.
### This goes in its own package because POE::Session and POE::NFA
### export conflicting constants.

package Switch;
use POE::NFA;

POE::NFA->spawn
  ( inline_states =>
    {
     # The initial state, and its start event.  Make the switch
     # visible by name, and start in the 'off' state.
     initial    =>
     { start    => sub { $_[KERNEL]->alias_set( 'switch' );
                         $_[MACHINE]->goto_state( 'off' );
                       },
       _default => sub { 0 },
     },
     # The light is off.  When this state is entered, post a
     # visibility event at whatever had caused the light to go off.
     # When it's pushed, have the light go on.
     off        =>
     { enter    => sub {
         $_[KERNEL]->post( $_[ARG0] => visibility => 0 );
       },
       pushed   => sub { $_[MACHINE]->goto_state( on => enter => $_[SENDER] );
                       },
       _default => sub { 0 },
     },
     # The light is on.  When this state is entered, post a visibility
     # event at whatever had caused the light to go on.  When it's
     # pushed, have the light go off.
     on         =>
     { enter    => sub {
         $_[KERNEL]->post( $_[ARG0] => visibility => 1 );
       },
       pushed   => sub {
         $_[MACHINE]->goto_state( off => enter => $_[SENDER] );
       },
       _default => sub { 0 },
     },
    },
  )->goto_state( initial => 'start' );  # enter the initial state

### This NFA uses the stop() method.  Gabriel Kihlman discovered that
### POE::NFA lags behind POE::Kernel after 0.24, and stop() wasn't
### fixed to use the new _data_ses_free() method of POE::Kernel.

POE::NFA->spawn
  ( inline_states =>
    { initial =>
      { start => sub { $_[MACHINE]->stop() }
      }
    }
  )->goto_state(initial => 'start');

### A plain session to interact with the switch.  It's in its own
### package to avoid conflicting constants.  This simulates a causal
### observer who pushes the light's button over and over, watching it
### as it goes on and off.

package Operator;
use POE::Session;
use TestSetup;

POE::Session->create
  ( inline_states =>
    {
     # Start by giving the session a name.  This keeps the session
     # alive while other sessions (the light) operate.  Set a test
     # counter, and yield to the 'push' handler.
     _start => sub {
       $_[KERNEL]->alias_set( 'operator' );
       $_[KERNEL]->yield( 'push' );
       $_[HEAP]->{push_count} = 0;
     },
     # Push the button, and count the button push for testing.
     push => sub {
       $_[HEAP]->{push_count}++;
       $_[KERNEL]->post( switch => 'pushed' );
     },
     # The light did something observable.  Check that its on/off
     # state matches our expectation.  If we need to test some more,
     # push the button again.
     visibility => sub {
       &ok_if( $_[HEAP]->{push_count},
               ($_[HEAP]->{push_count} & 1) == $_[ARG0]
             );
       $_[KERNEL]->yield( 'push' ) if $_[HEAP]->{push_count} < 10;
     },
     # Dummy handlers to avoid ASSERT_STATES warnings.
     _stop   => sub { 0 },
   }
  );

### This is a Fibonacci number servlet.  Post it a request with the F
### number you want, and it calculates and returns it.

package Server;
use POE::NFA;

POE::NFA->spawn
  ( inline_states =>
    {
     # Set up an alias so that clients can find us.
     initial =>
     { start => sub { $_[KERNEL]->alias_set( 'server' );
                      $_[MACHINE]->goto_state( 'listen' );
                    },
       _default => sub { 0 },
     },
     # Listen for a request.  The request includes which Fibonacci
     # number to return.
     listen =>
     { request => sub {
         $_[RUNSTATE]->{client} = $_[SENDER];
         $_[MACHINE]->call_state( answer    => # return event
                                  calculate => # new state
                                  start     => # new state's entry event
                                  $_[ARG0]     # F-number to return
                                );
       },
       answer => sub {
         $_[KERNEL]->post( delete($_[RUNSTATE]->{client}), 'fib', $_[ARG0] );
       },
       _default => sub { 0 },
     },
     calculate =>
     { start => sub {
         $_[MACHINE]->return_state( 0 ) if $_[ARG0] == 0;
         $_[MACHINE]->return_state( 1 ) if $_[ARG0] == 1;
         $_[RUNSTATE]->{f} = [ 0, 1 ];
         $_[RUNSTATE]->{n} = 1;
         $_[RUNSTATE]->{target} = $_[ARG0];
         $_[KERNEL]->yield( 'next' );
       },
       next => sub {
         $_[RUNSTATE]->{n}++;
         $_[RUNSTATE]->{f}->[2] =
           $_[RUNSTATE]->{f}->[0] + $_[RUNSTATE]->{f}->[1];
         shift @{$_[RUNSTATE]->{f}};
         if ($_[RUNSTATE]->{n} == $_[RUNSTATE]->{target}) {
           $_[MACHINE]->return_state( $_[RUNSTATE]->{f}->[1] );
         }
         else {
           $_[KERNEL]->yield( 'next' );
         }
       },
       _default => sub { 0 },
     },
    }
  )->goto_state( initial => 'start' );

### This is a Fibonacci client.  It asks for F numbers and checks the
### responses vs. expectations.

package Client;
use TestSetup;
use POE::Session;

my $test_number = 11;
my @test =
  ( [ 0, 0 ],
    [ 1, 1 ],
    [ 2, 1 ],
    [ 3, 2 ],
    [ 4, 3 ],
    [ 5, 5 ],

    [ 17, 1597 ],
    [ 23, 28657 ],
    [ 29, 514229 ],
    [ 43, 433494437 ],

  );

POE::Session->create
  ( inline_states =>
    { _start => sub {
        # Set up an alias so we'll stay alive until everything is done.
        $_[KERNEL]->alias_set( 'client' );
        $_[KERNEL]->yield( 'next_test' );
      },
      next_test => sub {
        $_[KERNEL]->post( server => request => $test[0]->[0] );
      },
      fib => sub {
        &ok_if( $test_number, $_[ARG0] == $test[0]->[1],
                "fib($test[0]->[0]) returned $_[ARG0] (wanted $test[0]->[1])"
              );
        shift @test;
        $test_number++;
        $_[KERNEL]->yield( 'next_test' ) if @test;
      },
      # Dummy handlers to avoid ASSERT_STATES warnings.
      _stop   => sub { 0 },
    },
  );

### Run everything until it's all done.  Display test results when
### everything is done, and exit.  Success!

package main;

$poe_kernel->run();
&results();

1;
