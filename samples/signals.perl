#!perl -w -I..
# $Id$

# Tests signals.  OS signals (such as SIGINT), soft signals to
# sessions, and signals to kernels.

use strict;
use POE; # and you get Kernel and Session

select(STDOUT); $|=1;

my $kernel = new POE::Kernel();

new POE::Session
  ( $kernel,
    '_start' => sub
    { my ($k, $me, $from) = @_;
      $k->sig('INT', 'signal handler');
      $k->sig('WHEE', 'signal handler');
      $k->sig('QUUX', 'signal handler');
      print "main signal watcher started... send SIGINT to stop.\n";
      $me->{'done'} = '';
      $k->delay('set an alarm', 1);
    },
    '_stop' => sub
    { my ($k, $me, $from) = @_;
      print "main signal watcher stopped.\n";
    },
    'set an alarm' => sub
    { my ($k, $me, $from) = @_;
      print "main alarm rang... sending SIGWHEE to main...\n";
      $k->signal($me, 'WHEE');
      $k->delay('set an alarm', 1);
    },
    'signal handler' => sub
    { my ($k, $me, $from, $signal_name) = @_;
      print "main caught SIG$signal_name\n";
      if ($signal_name eq 'INT') {
        print "main stopping signal watcher.\n";
        $k->delay('set an alarm');
      }
    },
  );

new POE::Session
  ( $kernel,
    '_start' => sub
    { my ($k, $me, $from) = @_;
      $k->sig('INT', 'signal handler');
      $k->sig('WHEE', 'signal handler');
      $k->sig('QUUX', 'signal handler');
      $k->delay('set an alarm', 0.5);
      print "second signal watcher started\n";
    },
    '_stop' => sub 
    { my ($k, $me, $from) = @_;
      print "second stopped.\n";
    },
    'set an alarm' => sub
    { my ($k, $me, $from) = @_;
      print "second alarm rang... sending SIGQUUX to kernel...\n";
      $k->signal($k, 'QUUX');
      $k->delay('set an alarm', 0.5);
    },
    'signal handler' => sub
    { my ($k, $me, $from, $signal_name) = @_;
      print "second caught SIG$signal_name\n";
      if ($signal_name eq 'INT') {
        print "second stopping...\n";
        $k->delay('set an alarm');
      }
    },
 );

$kernel->run();
