#!perl -w -I..
# $Id$

# Filter::Reference test, part 2 of 2.
# This program freezes referenced data, and sends it to a waiting
# copy of refserver.perl.

# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Rewritten to use POE to exercise Filter::Reference::put()

use strict;

use POE qw(Wheel::ReadWrite Driver::SysRW Filter::Reference);
use IO::Socket;

my $kernel = new POE::Kernel();

#------------------------------------------------------------------------------

new POE::Session
  ( $kernel,
    '_start' => sub
    { my ($k, $me, $from) = @_;
      my $socket = new IO::Socket::INET
        ( PeerAddr => '127.0.0.1:31338', # eleet++
          Reuse => '1',
          Proto => 'tcp',
        );
      if ($socket) {
        $me->{'wheel'} = new POE::Wheel::ReadWrite
          ( $kernel,
            'Handle' => $socket,
            'Driver' => new POE::Driver::SysRW(),
            'Filter' => new POE::Filter::Reference(),
            'InputState' => 'got reference',
            'ErrorState' => 'error',
            'FlushedState' => 'sent all'
          );
                                        # send objects
        $me->{'wheel'}->put
          ( (bless { site => 'wdb', id => 1 }, 'kristoffer'),
            (bless [ qw(one two three four) ], 'roch'),
            \ "this is an unblessed scalar thingy"
          );
      }
      else {
        warn "could not connect to 127.0.0.1:31338 - $!";
      }
    },
                                        # register any errors
    'error' => sub
    { my ($k, $me, $from, $operation, $errnum, $errstr) = @_;
      print "$operation error: ($errnum) $errstr\n";
    },
                                        # watch for input (?!)
    'got reference' => sub
    { my ($k, $me, $from, $reference) = @_;
      print "recevied a reference: $reference\n";
    },
                                        # shut down after everything is sent
    'sent all' => sub
    { my ($k, $me, $from) = @_;
      print "all references sent.  goodbye...\n";
      delete $me->{'wheel'};
    },
  );

#------------------------------------------------------------------------------

$kernel->run();

exit;

