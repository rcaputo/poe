#!perl -w -I../lib
# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This is a pre-release version.  Redistribution and modification are
# prohibited.

package main;
use strict;
use POE::Kernel;
use POE::Session;

open STDERR, '>&STDOUT';

my $kernel = new POE::Kernel();
my $forkbomber = 0;

sub forkbomb {
  my $kernel = shift;

  new POE::Session
    (
     $kernel,
     '_start' => sub
     {
       my ($k, $me, $from) = @_;
       $me->{'id'} = ++$forkbomber;
       print $me->{'id'}, ": starting...\n";
       $k->post_state($me, 'fork');
     },
     '_stop' => sub
     {
       my ($k, $me, $from) = @_;
       print $me->{'id'}, ": stopping...\n";
     },
     '_child' => sub
     {
       my ($k, $me, $child_session) = @_;
       print $me->{'id'}, ": child $child_session stopped...\n";
     },
     '_parent' => sub
     {
       my ($k, $me, $new_parent) = @_;
       print $me->{'id'}, ": parent now is $new_parent ...\n";
     },
     'fork' => sub
     {
       my ($k, $me, $from) = @_;
       print $me->{'id'}, ": starting new child...\n";
       if ($forkbomber < 1000) {
         &forkbomb($k);
         if (($forkbomber < 500) || (rand() < 0.5)) {
           $k->post_state($me, 'fork');
         }
         else {
           print $me->{'id'}, ": preparing to stop...\n";
         }
       }
       else {
         print $me->{'id'}, ": forkbomber limit reached, b'bye!\n";
       }
     },
    );
}

#------------------------------------------------------------------------------

&forkbomb($kernel);

$kernel->run();
