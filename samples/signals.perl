#!perl -w -I../lib
# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This is a pre-release version.  Redistribution and modification are
# prohibited.

use strict;

use POE::Kernel;
use POE::Session;

select(STDOUT); $|=1;

my $kernel = new POE::Kernel();

new POE::Session
  (
   $kernel,
   '_start' => sub
   {
     my ($k, $me, $from) = @_;
     $k->sig('INT', 'signal handler');
     print "Signal watcher started.  Send SIGINT: ";
     $k->post($me, 'set an alarm');
   },
   '_stop' => sub
   {
     my ($k, $me, $from) = @_;
     print "Signal watcher stopped.\n";
   },
   '_default' => sub
   {
     my ($k, $me, $from, $state, @etc) = @_;
     print "Signal watcher _default gets state ($state) from ($from) ",
           "parameters(", join(', ', @etc), ")\n";
   },
   'set an alarm' => sub
   {
     my ($k, $me, $from, $name) = @_;
     print ".";
     $k->alarm('set an alarm', time()+1);
   },
   'signal handler' => sub
   {
     my ($k, $me, $from, $signal_name) = @_;
     print "\nSignal watcher caught SIG$signal_name.\n";
   },
  );


$kernel->run();
