#!/usr/bin/perl -w -I..
# $Id$

# This is a simple Object Layer functionality test.  It contains a
# simple "soft" object repository that works like the sessions.perl
# example.

# This code is experimental.  Everything in the Object Layer is
# subject to change, with no backward compatibility guarantees.

use strict;
use POE qw(Runtime Repository::Array Curator);

close STDERR;
open STDERR, '>&STDOUT';
select(STDERR); $|=1;
select(STDOUT); $|=1;

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
# ME = A reference to the current object.  This is an alias for
# POE::Session::OBJECT.
#
# SESSION = undef.  Objects should not have to worry about sessions.
# KERNEL  = undef.  Objects should not have to deal with the Kernel.
#
#   SESSION and KERNEL will be supplied to objects owned by "root"
#   type users.  This should allow secure, controlled access to the
#   low-level POE functions.
#
# HEAP   = The current session's heap.  This is runtime environment.
#
# METHOD = The name of the object method being run.  Pointless?
# ACTOR  = A reference to the object that invoked this one.
# ARG0..ARG9 = Parameters passed to post() or spawn().

# Object attributes that are used by the object layer:
#
# session_leader
#
#   Not currently used.  session_leader causes post() to behave
#   differently.  If the object containing session_leader has been
#   spawned in its own session, then any events posted to it will run
#   in the controlling session-- NOT THE POSTER'S SESSION!
#
#   Spawning objects with a boolean false session_leader is undefined.
#
#   Posting events to a session_leader that has no controlling session
#   is undefined.
#
# parent
#
#   Used to find attributes in objects' ancestors.

# TO DO:
#
# Exception model.  It should be neat, tidy, and contain an enormous
# amount of syntactic sugar to hide what surely will be lots of gross
# guts.
#
# Map Object.pm into an "object" object, so that most of the object
# model may be coded from within itself. :)

#------------------------------------------------------------------------------
# This is a sample object repository.  It is meant to work like the
# sessions.perl sample.

my $repository =

  # Object 0: This is the absolute base object.  If the repository was
  # a tree (which it is) then this would be the trunk.

  [ { name                  => 'object',
      name_can_fetch        => 1,
      name_did_fetch        => <<'      End Of Method',
        my ($me, $actor, $old, $new) = @_[ME, ACTOR, ARG0, ARG1];
        print ",----- object.name_did_fetch -----\n";
        print "| actor($actor->{id}) me($me->{id})\n";
        print "| old value: $old\n";
        print "| new value: $new\n";
        print "`---------------------------------\n";
      End Of Method
      name_can_store        => <<'      End Of Method',
        my ($me, $actor, $old, $new) = @_[ME, ACTOR, ARG0, ARG1];
        print ",----- object.name_can_store -----\n";
        print "| actor($actor->{id}) me($me->{id})\n";
        print "| old value: $old\n";
        print "| new value: $new\n";
        print "`---------------------------------\n";
        ($actor->{id} == $me->{owner});
      End Of Method
      name_did_store        => <<'      End Of Method',
        my ($me, $actor, $old, $new) = @_[ME, ACTOR, ARG0, ARG1];
        print ",----- object.name_did_store -----\n";
        print "| actor($actor->{id}) me($me->{id})\n";
        print "| old value: $old\n";
        print "| new value: $new\n";
        print "`---------------------------------\n";
      End Of Method

      description           => 'The absolute base object.',
      description_can_fetch => 1,
      description_did_fetch => <<'      End Of Method',
        my ($me, $actor, $old, $new) = @_[ME, ACTOR, ARG0, ARG1];
        print ",----- object.description_did_fetch -----\n";
        print "| actor($actor->{id}) me($me->{id})\n";
        print "| old value: $old\n";
        print "| new value: $new\n";
        print "`----------------------------------------\n";
      End Of Method
      description_can_store => <<'      End Of Method',
        my ($me, $actor, $old, $new) = @_[ME, ACTOR, ARG0, ARG1];
        print ",----- object.description_can_store -----\n";
        print "| actor($actor->{id}) me($me->{id})\n";
        print "| old value: $old\n";
        print "| new value: $new\n";
        print "`----------------------------------------\n";
        ($actor->{id} == $me->{owner});
      End Of Method
      description_did_store => <<'      End Of Method',
        my ($me, $actor, $old, $new) = @_[ME, ACTOR, ARG0, ARG1];
        print ",----- object.description_did_store -----\n";
        print "| actor($actor->{id}) me($me->{id})\n";
        print "| old value: $old\n";
        print "| new value: $new\n";
        print "`----------------------------------------\n";
      End Of Method

      parent                => undef,
      parent_can_fetch      => 1,
      parent_reciprocal     => 'children',

      children              => [],
      children_can_fetch    => 1,

      owner                 => undef,
      owner_can_fetch       => 1,
      owner_reciprocal      => 'owns',

      describe => <<'      End Of Method',
        my ($object, $sender) = @_[ME, ACTOR];
        print( "--- I am the object named '$object->{name}' ",
               "(called by $sender)\n"
             );
      End Of Method
    },

    # Object 1: This is a "counter" object.  Its "start" method
    # accepts a session ID, and it will post "increment" events to
    # itself until its counter reaches a certain limit.

    { name => 'counter',
      parent => 0,
      owner => 2,

      start => <<'      End Of Method',
        my ($object, $heap, $id) = @_[ME, HEAP, ARG0];
        $object->post('describe');
        $heap->{counter} = 1;
        $heap->{id} = $id;
        print "--- $object->{name} $id starting ...\n";
        $object->post('increment');
      End Of Method

      increment => <<'      End Of Method',
        my ($object, $heap) = @_[ME, HEAP];
        $object->post('describe');
        print "--- $object->{name} $heap->{id} iteration $heap->{counter}\n";
        if ($heap->{counter} < 10) {
          $heap->{counter}++;
          $object->post('increment');
        }
        else {
          print "--- $object->{name} $heap->{id} finished.\n";
        }
      End Of Method
    },

    # Object 2: This is a "main" object, borrowing its name from the C
    # "main" function.  Its "bootstrap" method spawns certain number
    # of start sessions.  I think it will be useful to have a
    # &POE::Object::detach method that spawns objects in new sessions
    # that aren't considered children of the current session.

    { name => 'main',
      parent => 0,
      owner => 2,

      bootstrap => <<'      End Of Method',
        $_[ME]->post('describe');
        for (my $session_id=0; $session_id<10; $session_id++) {
          object('counter')->spawn('start', $session_id);
        }
      End Of Method
    },

    # Object 3: This tests store.

    { name => 'storetest',
      description => 'This object tests store/fetch with side-effects.',
      parent => 0,
      owner => 3,

      hash => { one => 'this is one', two => 'this is two' },
      hash_can_fetch => 1,
      list => [ 'this is zero', 'this is one', 'this is two' ],
      list_can_fetch => 1,

      test => <<'      End Of Method',
        print ">>> Now $_[ME]->{name} value: $_[ME]->{description}\n";
        $_[ME]->{description} = 'This tests attribute storing.';
        print ">>> New $_[ME]->{name} value: $_[ME]->{description}\n";

        my $object = object('object');
        print ">>> Now $object->{name} description: $object->{description}\n";
        $object->{description} = 'New description here!';
        print ">>> New $object->{name} description: $object->{description}\n";

        $object = object('storetest');
        print ">>> Now $object->{name} hash: $object->{hash}->{one}\n";
        print ">>> Now $object->{name} list: $object->{list}->[0]\n";
      End Of Method
    },
  ];

# Initialize the curator.  Give it a repository to work with.  This
# will expand, DBI-like to allow for different types of back-end
# storage.  This type of repository might be "POE::Repository::Array".
# Another useful repository type might be "POE::Repository::DBI".

my $curator = new POE::Curator
  ( Repository => new POE::Repository::Array($repository)
  );

initialize POE::Runtime Curator => $curator;

# Use the Curator's &object function to fetch a reference to a
# database object.  Use the reference to spawn a method in a new
# session.  This bootstraps the object environment.

#$curator->object('main')->spawn('bootstrap');
$curator->object('counter')->spawn('start', 'one');

# Start the POE kernel.

$poe_kernel->run();

exit;
