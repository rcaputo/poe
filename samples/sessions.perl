#!perl -w -I..
# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This is a pre-release version.  Redistribution and modification are
# prohibited.

use strict;

use POE; # Kernel and Session are always included

my $kernel = new POE::Kernel();

foreach my $session_name
  (
   qw(one two three four five six seven eight nine ten)
  )
{
  new POE::Session
    (
     $kernel,

     '_start' => sub
     {
       my ($k, $me, $from) = @_;
       $me->{'name'} = $session_name;
       $k->sig('INT', 'sigint');
       $k->post($me, 'increment', $session_name, 0);
       print "Session $session_name started.\n";
     },
     '_stop' => sub
     {
       my ($k, $me, $from) = @_;
       print "Session ", $me->{'name'}, " stopped.\n";
     },
     '_default' => sub
     {
       my ($k, $me, $from, $state, @etc) = @_;
       print "Session ", $me->{'name'}, " _default got state ($state) ",
             "from ($from) parameters (", join(', ', @etc), ")\n";
     },
     'increment' => sub
     {
       my ($k, $me, $from, $session_name, $counter) = @_;
       $counter++;
       print "Session $session_name, iteration $counter.\n";
       if ($counter < 5) {
         $k->post($me, 'increment', $session_name, $counter);
       }
       else {
         # no more states; nothing left to do.  session stops.
       }
     },
    );
}

$kernel->run();
