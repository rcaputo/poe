#!/usr/bin/perl -w

# This program tests signals.  It tests OS signals (such as SIGINT),
# soft signals to sessions, and soft signals to kernels.  Soft
# signals, by the way, are ones generated with the Kernel::signal()
# function.  They don't involve the underlying OS, and so can send
# arbitrarily named signals.

use strict;
use lib '../lib';
use POE;

#==============================================================================
# This is a pathological example of an inline session.  It defines the
# subs for each event handler within the POE::Session constructor's
# parameters.  It's not bad for quick hacks.
#
# Anyway, this session registers handlers for SIGINT and two
# fictitious signals (SIGFOO and SIGQUUX).  The session then starts an
# alarm loop that signals FOO to itself once a second.

POE::Session->create(
  inline_states => {
                                        ### _start the session
    '_start' => sub{
      my $kernel = $_[KERNEL];
                                        # register signal handlers
      $kernel->sig('INT', 'signal handler');
      $kernel->sig('FOO', 'signal handler');
      $kernel->sig('QUUX', 'signal handler');
                                        # hello, world!
      print "First session started... send SIGINT to stop.\n";
                                        # start the alarm loop
      $kernel->delay('set an alarm', 1);
    },
                                        ### _stop the session
    '_stop' => sub {
      print "First session stopped.\n";
    },
                                        ### alarm handler
    'set an alarm' => sub {
      my ($kernel, $session) = @_[KERNEL, SESSION];
      print "First session's alarm rang.  Sending SIGFOO to itself...\n";
                                        # send a signal to itself
      $kernel->signal($session, 'FOO');
                                        # reset the alarm for 1s from now
      $kernel->delay('set an alarm', 1);
    },
                                        ### signal handler
    'signal handler' => sub {
      my ($kernel, $signal_name) = @_[KERNEL, ARG0];
      print "First session caught SIG$signal_name\n";
      print(
        "First session's pending alarms: ",
         join(':', map { "\"$_\"" } $kernel->queue_peek_alarms()), "\n"
      );
                                        # stop pending alarm on SIGINT
      if ($signal_name eq 'INT') {
        print "First session stopping...\n";
        $kernel->delay('set an alarm');
      }
    },
  }
);

#==============================================================================
# This is another pathological inline session.  This one registers
# handlers for SIGINT and two fictitious signals (SIGBAZ and SIGQUUX).
# The session then starts an alarm loop that signals QUUX to the
# kernel twice a second.  This propagates SIGQUUX to every session.

POE::Session->create(
  inline_states => {
                                        ### _start the session
    '_start' => sub {
      my $kernel = $_[KERNEL];
                                        # register signal handlers
      $kernel->sig('INT', 'signal handler');
      $kernel->sig('BAZ', 'signal handler');
      $kernel->sig('QUUX', 'signal handler');
                                        # hello, world!
      print "Second session started... send SIGINT to stop.\n";
                                        # start the alarm loop
      $kernel->delay('set an alarm', 0.5);
    },
                                        ### _stop the session
    '_stop' => sub {
      print "Second session stopped.\n";
    },
                                        ### alarm handler
    'set an alarm' => sub {
      my $kernel = $_[KERNEL];
      print "Second session's alarm rang.  Sending SIGQUUX to kernel...\n";
                                        # signal the kernel
      $kernel->signal($kernel, 'QUUX');
                                        # reset the alarm for 1/2s from now
      $kernel->delay('set an alarm', 0.5);
    },
                                        ### signal handler
    'signal handler' => sub {
      my ($kernel, $signal_name) = @_[KERNEL, ARG0];
      print "Second session caught SIG$signal_name\n";
      print( "Second session's pending alarms: ",
             join(':', $kernel->queue_peek_alarms()), "\n"
           );
                                        # stop pending alarm on SIGINT
      if ($signal_name eq 'INT') {
        print "Second session stopping...\n";
        $kernel->delay('set an alarm');
      }
    },
  }
);

#==============================================================================
# Tell the kernel to run the sessions.

$poe_kernel->run();

exit;
