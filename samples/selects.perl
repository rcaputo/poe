#!perl -w -I../lib
# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This is a pre-release version.  Redistribution and modification are
# prohibited.

use strict;

use POE::Kernel;
use POE::Session;
use IO::Socket::INET;
use POSIX;                              # for EAGAIN

my $kernel = new POE::Kernel();

#------------------------------------------------------------------------------
# Chargen server.

new POE::Session
  (
   $kernel,
   '_start' => sub
   {
     my ($k, $me, $from) = @_;
     print "Starting chargen server on port 30019 ...\n";
     my $listener = new IO::Socket::INET('LocalPort' => 30019,
                                         'Listen'    => 5,
                                         'Proto'     => 'tcp',
                                         'Reuse'     => 'yes',
                                        );
                                        # give the handle to the kernel
     if ($listener) {
       $k->select($listener, 'accept');
     }
     else {
       warn "chargen service not started - listen on 30019 failed: $!";
     }
   },
   '_stop' => sub
   {
     my ($k, $me, $from) = @_;
     print "Stopping chargen server ...\n";
   },
   '_child' => sub
   {
     my ($k, $me, $child_session) = @_;
     print "Chargen server's child session ($child_session) has stopped.\n";
   },
   '_parent' => sub
   {
     my ($k, $me, $new_parent) = @_;
     print "Parent of chargen server is now ($new_parent).\n";
   },
                                        # start soft states
   'accept' => sub
   {
     my ($k, $me, $from, $handle) = @_;
     print "Chargen server sees an incoming connection.\n";
     my $connection = $handle->accept();
     if ($connection) {
       my $peer_host = $connection->peerhost();
       my $peer_port = $connection->peerport();
                                        # start generating characters!
       new POE::Session
         (
          $k,
          '_start' => sub
          {
            my ($k, $me, $from) = @_;
            print "Starting chargen service for $peer_host:$peer_port ...\n";
            $me->{'char'} = 32;
            $k->select($connection, 'read', 'write');
          },
          '_stop' => sub {
            my ($k, $me, $from) = @_;
            print "Chargen service stopped.\n";
          },
                                        # consume anything sent
          'read' => sub {
            my ($k, $me, $from, $handle) = @_;
            1 while (sysread($handle, my $buffer = '', 1024));
          },
                                        # can write, so do
          'write' => sub
          {
            my ($k, $me, $from, $handle) = @_;
            my $str = '';
            my $j = $me->{'char'};
            my $i = 0;
            while ($i++ < 72) {
              $str .= chr($j);
              $j = 32 if (++$j > 126);
            }
            $me->{'char'} = 32 if (++$me->{'char'} > 126);
            $str .= "\x0D\x0A";
                                        # write it
            my ($offset, $to_write) = (0, length($str));
            while ($to_write) {
              my $sub_wrote = syswrite($handle, $str, $to_write, $offset);
              if ($sub_wrote) {
                $offset += $sub_wrote;
                $to_write -= $sub_wrote;
              }
              elsif ($!) {
                                        # close session on error
                print "closing chargen server connection (write error: $!)\n";
                $k->select($handle);
                last;
              }
            }
          },
         );
     }
     else {
       if ($! == EAGAIN) {
         print "Incoming chargen server connection not ready... try again!\n";
         $k->post_state($me, 'accept', $handle);
       }
       else {
         print "Incoming chargen server connection failed: $!\n";
       }
     }
   }
  );

#------------------------------------------------------------------------------
# Chargen client.

new POE::Session
  (
   $kernel,
   '_start' => sub
   {
     my ($k, $me, $from) = @_;
     print "Starting chargen client ...\n";
     $me->{'lines read'} = 0;
     my $listener = new IO::Socket::INET('PeerHost' => 'localhost',
                                         'PeerPort' => 30019,
                                         'Proto'    => 'tcp',
                                         'Reuse'    => 'yes',
                                        );
                                        # give the handle to the kernel
     if ($listener) {
       $k->select($listener, 'read', undef, 'except');
     }
     else {
       warn "chargen client not started - connect failed: $!";
     }
   },
   '_stop' => sub
   {
     my ($k, $me, $from) = @_;
     print "Stopping chargen client ...\n";
   },
   '_child' => sub
   {
     my ($k, $me, $child_session) = @_;
     print "Chargen client child session ($child_session) has stopped.\n";
   },
   '_parent' => sub
   {
     my ($k, $me, $new_parent) = @_;
     print "Parent of chargen client is now ($new_parent).\n";
   },
                                        # start soft states
   'read' => sub
   {
     my ($k, $me, $from, $handle) = @_;
     while (sysread($handle, my $buffer = '', 1024)) {
       print $buffer;
       $me->{'lines read'} += ($buffer =~ s/(\x0D\x0A)/$1/g);
       if ($me->{'lines read'} > 5) {
         $k->select($handle, undef, undef, undef);
       }
     }
   },
   'except' => sub
   {
     my ($k, $me, $from, $handle) = @_;
     print "chargen client has exception on $handle\n";
                                        # remove the select; stops the session
                                        # when all pending states are done
     $k->select($handle);
   },
  );

#------------------------------------------------------------------------------
# Start your engines.

$kernel->run();
