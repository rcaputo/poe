#!perl -w -I../lib
# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This is a pre-release version.  Redistribution and modification are
# prohibited.

use strict;

use POE::Kernel;
use POE::Session;

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
        print "Starting session $session_name.\n";
        $me->{'name'} = $session_name;
        $k->post_state($me, 'increment', $session_name, 0);
      },
      '_stop' => sub
      {
        my ($k, $me, $from) = @_;
        print "Stopping session ", $me->{'name'}, ".\n";
      },
      '_child' => sub
      {
        my ($k, $me, $child_session) = @_;
        print "Child session ($child_session) had stopped.\n";
      },
      '_parent' => sub
      {
        my ($k, $me, $new_parent) = @_;
        print "Parent has changed to ($new_parent).\n";
      },
      'increment' => sub
      {
        my ($k, $me, $from, $session_name, $counter) = @_;
        $counter++;
        print "Session $session_name, iteration $counter.\n";
        if ($counter < 5) {
          $k->post_state($me, 'increment', $session_name, $counter);
        }
        else {
          # no more states; session should stop
        }
      },

    );
}

$kernel->run();
