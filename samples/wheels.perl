#!perl -w -I../lib
# $Id$

# See selects.perl for a lower-level approach to accepting connections,
# driving sockets and filtering IO.  Wheels were thunk up to replace the
# most common things in selects.perl with reusable boilerplates.

use strict;
                                        # need to combine into one happy "use"?
use POE::Kernel;
use POE::Session;
use POE::Wheel::ListenAccept;
use POE::Wheel::ReadWrite;
use POE::Driver::SysRW;
use POE::Filter::Line;

use IO::Socket::INET;

my $kernel = new POE::Kernel();

my $rot13_port = 32000;

#------------------------------------------------------------------------------

new POE::Session
  (
   $kernel,
   '_start' => sub
   {
     my ($k, $me, $from) = @_;
     if (
         my $listener = new IO::Socket::INET
         ( 'LocalPort' => $rot13_port,
           'Listen'    => 5,
           'Proto'     => 'tcp',
           'Reuse'     => 'yes',
         )
     ) {
       $me->{'wheel'} = new POE::Wheel::ListenAccept
         ( $kernel,
           'Handle'      => $listener,
           'AcceptState' => 'accept',
           'ErrorState'  => 'accept error'
         );
       print "= rot-13 server listening on port $rot13_port\n";
     }
     else {
       warn "rot13 server didn't start: $!";
     }
   },
   'accept error' => sub
   { my ($k, $me, $from, $operation, $errnum, $errstr) = @_;
     print "! $operation error $errnum: $errstr\n";
   },
   'accept' => sub
   {
     my ($k, $me, $from, $accepted_handle) = @_;

     my ($peer_host, $peer_port) =
       ( $accepted_handle->peerhost(),
         $accepted_handle->peerport()
       );
                                        # spawn off a connection handler
     new POE::Session
       ( $k,
         '_start' => sub
         { my ($k, $me, $from) = @_;
                                        # sysread/syswrite/line-filter
           $me->{'wheel'} = new POE::Wheel::ReadWrite
             ( $kernel,
               'Handle' => $accepted_handle,
               'Driver' => new POE::Driver::SysRW(),
               'Filter' => new POE::Filter::Line(),
               'InputState' => 'got a line',
             );

           $me->{'wheel'}->put
             ("Greetings, $peer_host $peer_port!  Type some text!");

           print "> begin rot-13 session with $peer_host:$peer_port\n";
         },

         '_stop' => sub
         { my ($k, $me, $from) = @_;
           print "< cease rot-13 session with $peer_host:$peer_port\n";
         },
                                        # rot-13 received lines
         'got a line' => sub {
           my ($k, $me, $from, $line) = @_;
                                        # rot-13 it
           $line =~ tr[a-zA-Z][n-za-mN-ZA-M];
                                        # give it to the wheel
           $me->{'wheel'}->put($line);
         },
       );
   }
  );

#------------------------------------------------------------------------------
# Start your engines.

$kernel->run();
