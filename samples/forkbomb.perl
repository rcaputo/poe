#!perl -w -I..
# $Id$

package main;
use strict;

use POE; # POE::Kernel and POE::Session are included automagically

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
       $k->sig('INT', 'signal handler');
       $k->post($me, 'fork');
     },
     '_stop' => sub
     {
       my ($k, $me, $from) = @_;
       print $me->{'id'}, ": stopped.\n";
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
     '_default' => sub
     {
       my ($k, $me, $from, $state, @etc) = @_;
       print $me->{'id'}, ": _default got state ($state) from ($from) ",
             "parameters(", join(', ', @etc), ")\n";
       return 0;
     },
     'signal handler' => sub
     {
       my ($k, $me, $from, $signal) = @_;
       print $me->{'id'}, ": caught SIG$signal\n";
       return 0;
     },
     'fork' => sub
     {
       my ($k, $me, $from) = @_;
       print $me->{'id'}, ": starting new child...\n";
       if ($forkbomber < 100) {
         &forkbomb($k);
         if (($forkbomber < 50) || (rand() < 0.5)) {
           $k->post($me, 'fork');
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
