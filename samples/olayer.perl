#!/usr/bin/perl -w -I..
# $Id$

# This is a simple Object Layer functionality test.  It contains a
# simple "soft" object repository that works like the sessions.perl
# example.

# This code is experimental.  Everything in the Object Layer is
# subject to change, with no backward compatibility guarantees.

use strict;
use POE qw(Object Curator Runtime);

print '-' x 70, "\n";

# Notes on some of the hidden things:
#
# $object->post() fires an event at an object within the same session.
# $object->spawn() fires an event at an object in a new session.
#
# The "Object Layer" is reusing the session parameter constants, but
# some of the meanings have changed.  Here are the parameters and how
# I'm currently using them:
#
# OBJECT  = A reference to the current object.
# SESSION = undef.  Objects should not have to worry about sessions.
# KERNEL  = undef.  Objects should not have to deal with the Kernel.
# HEAP    = The current session's heap.  This is runtime environment.
# STATE   = The name of the object method being run.  Pointless?
# SENDER  = -1.  This will be a reference to the poster/spawner object.
# ARG0..ARG9 = Parameters passed to post() or spawn().

#------------------------------------------------------------------------------
# This is a sample object repository.  It is meant to work like the
# sessions.perl sample.

my $repository =

  # This is the base "object".  It will be required.  This object
  # receives the regular @_[SESSION, KERNEL] parameters.

  [ { name => 'object',

      post => <<'      End Of Method',
        $_[KERNEL]->yield('curator_post', $_[OBJECT], $_[ARG0], $_[ARG1]);
      End Of Method

      spawn => <<'      End Of Method',
      End Of Method
    },

    # This is a "counter" object.  Its "start" method accepts a
    # session ID, and it will post "increment" events to itself until
    # its counter reaches a certain limit.

    { name => 'counter',

      start => <<'      End Of Method',
        my ($object, $heap, $id) = @_[OBJECT, HEAP, ARG0];
        $heap->{counter} = 1;
        $heap->{id} = $id;
        print "--- counter $id starting ...\n";
        $object->post('increment');
      End Of Method

      increment => <<'      End Of Method',
        my ($object, $heap) = @_[OBJECT, HEAP];
        print "--- counter $heap->{id} iteration $heap->{counter}\n";
        if ($heap->{counter} < 10) {
          $heap->{counter}++;
          $object->post('increment');
        }
        else {
          print "--- counter $heap->{id} finished.\n";
        }
      End Of Method
    },

    # This is a "main" object, borrowing its name from the C "main"
    # function.  Its "bootstrap" method spawns certain number of start
    # sessions.  I think it will be useful to have a
    # &POE::Object::detach method that spawns objects in new sessions
    # that aren't considered children of the current session.

    { name => 'main',

      bootstrap => <<'      End Of Method',
        for (my $session_id=0; $session_id<10; $session_id++) {
          object('counter')->spawn('start', $session_id);
        }
      End Of Method
    }
  ];

# Initialize the curator.  Give it a repository to work with.  This
# will expand, DBI-like to allow for different types of back-end
# storage.  This type of repository might be "POE::Repository::Array".
# Another useful repository type might be "POE::Repository::DBI".

initialize POE::Curator( Repository => $repository );

# Use the Curator's &object function to fetch a reference to a
# database object.  Use the reference to spawn a method in a new
# session.  This bootstraps the object environment.

POE::Curator::object('main')->spawn('bootstrap');

# Start the POE kernel.

$poe_kernel->run();

exit;
