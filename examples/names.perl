#!/usr/bin/perl -w

# Aliases were originally called Names.

# Sessions with aliases will remain active even if they have nothing
# to do.  They still get SIGZOMBIE when all the other sessions run out
# of things to do, so programs with aliased sessions won't run
# forever.  Aliases are mainly useful for creating "daemon" sessions
# that can be called upon by other sessions.

# This example is kind of obsolete.  Session postbacks have been
# created in the meantime, allowing it to totally avoid the kludgey
# timer loops.

use strict;
use lib '../lib';
use POE;

#==============================================================================
# The LockDaemon package defines a session that provides simple
# resource locking.  This is only available within the current
# process.

package LockDaemon;

use strict;
use POE::Session;

#------------------------------------------------------------------------------
# Create the LockDaemon.  This illustrates non-POE objects that
# register themselves with POE during construction.

sub new {
  my $type = shift;
  my $self = bless { }, $type;
                                        # hello, world!
  print "> $self created\n";
                                        # give this object to POE
  POE::Session->create(
    object_states => [
      $self, [ qw(_start _stop lock unlock sighandler) ]
    ]
  );

  # Don't let the caller have a reference.  It's not very nice, but it
  # also prevents the caller from holding onto the reference and
  # possibly leaking memory.

  undef;
}

#------------------------------------------------------------------------------
# Destroy the server.  This will happen after its POE::Session stops
# and lets go of the object reference.

sub DESTROY {
  my $self = shift;
  print "< $self destroyed\n";
}

#------------------------------------------------------------------------------
# This method handles POE's standard _start message.  It registers an
# alias for the session, sets up signal handlers, and tells the world
# what it has done.

sub _start {
  my $kernel = $_[KERNEL];

  # Set the alias.  This really should check alias_set's return value,
  # but it's being lame.

  $kernel->alias_set('lockd');
                                        # register signal handlers
  $kernel->sig('INT', 'sighandler');
  $kernel->sig('IDLE', 'sighandler');
  $kernel->sig('ZOMBIE', 'sighandler');
                                        # hello, world!
  print "+ lockd started.\n";
}

#------------------------------------------------------------------------------
# This method handles signals.  It really only acknowledges that a
# signal has been received.

sub sighandler {
  my $signal_name = $_[ARG0];

  print "@ lockd caught and handled SIG$signal_name\n";

  # Returning a boolean true value indicates to the kernel that the
  # signal was handled.  This usually means that the session will not
  # be stopped.

  return 1;
}

#------------------------------------------------------------------------------
# This method handles POE's standard _stop event.  It cleans up after
# the session by removing its alias.

sub _stop {
  my ($object, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];
  $kernel->alias_remove('lockd');
  print "- lockd stopped.\n";
}

#------------------------------------------------------------------------------
# Attempt to acquire a lock.  This implements a very basic callback
# protocol.  If the lock can be acquired, the caller's $success state
# is invoked.  If the lock fails, the caller's $failure state is
# invoked.  It's up to the caller to keep itself alive, most likely
# with a timeout event.

sub lock {
  my ($kernel, $heap, $sender, $lock_name, $success, $failure) =
    @_[KERNEL, HEAP, SENDER, ARG0, ARG1, ARG2];
                                        # if the lock already exists...
  if (exists $heap->{$lock_name}) {
                                        # ... check the current lock
    my ($owner, $time) = @{$heap->{$lock_name}};
                                        # ... same owner?
    if ($owner eq $sender) {
                                        # ... ... refresh lock & succeed
      $heap->{$lock_name}->[1] = time();
      $kernel->post($sender, $success);
      return 0;
    }
                                        # ... different owner?  fail!
    $kernel->post($sender, $failure);
    return 0;
  }
                                        # no pre-existing lock; so acquire ok
  $heap->{$lock_name} = [ $sender, time() ];
  $kernel->post($sender, $success);
}

#------------------------------------------------------------------------------
# Attempt to release a lock.  This implements a very basic callback
# protocol, similar to lock's.

sub unlock {
  my ($kernel, $heap, $sender, $lock_name, $success, $failure) =
    @_[KERNEL, HEAP, SENDER, ARG0, ARG1, ARG2];
                                        # if the lock exists...
  if (exists $heap->{$lock_name}) {
                                        # ... check the existing lock
    my ($owner, $time) = @{$heap->{$lock_name}};
                                        # ... same owner?
    if ($owner eq $sender) {
                                        # ... ... release the lock & succeed
      delete $heap->{$lock_name};
      $kernel->post($sender, $success);
      return 0;
    }
  }
                                        # no lock by that name; fail
  $kernel->post($sender, $failure);
  return 0;
}

#==============================================================================
# The LockClient package defines a session that wants to do some
# things to a resource that it must hold a lock for, and some other
# things when it doesn't need to hold a lock.

package LockClient;

use strict;
use POE::Session;

#------------------------------------------------------------------------------
# Create the LockClient.  This also illustrates non-POE objects that
# register themselves with POE during construction.  The LockDaemon
# constructor is better documented, though.

sub new {
  my ($type, $name) = @_;
  my $self = bless { 'name' => $name }, $type;
                                        # hello, world!
  print "> $self created\n";
                                        # give this object to POE
  POE::Session->create(
    object_states => [
      $self,
      [ qw(_start _stop
        acquire_lock retry_acquire
        release_lock retry_release
        perform_locked_operation perform_unlocked_operation
        )
      ],
    ]
  );
                                        # it will manage itself, thank you
  undef;
}

#------------------------------------------------------------------------------
# Destroy the client.  This will happen after its POE::Session stops
# and lets go of the object reference.

sub DESTROY {
  my $self = shift;
  print "< $self destroyed\n";
}

#------------------------------------------------------------------------------
# This method handles POE's standard _start message.  It starts the
# client's main loop by first performing an operation without holding
# a lock.

sub _start {
  my ($kernel, $session, $object) = @_[KERNEL, SESSION, OBJECT];
                                        # display some impressive output :)
  print "+ client $object->{'name'} started\n";
                                        # move to the next state in the cycle
  $kernel->post($session, 'perform_unlocked_operation');
}

#------------------------------------------------------------------------------
# This method handles POE's standard _stop message.  Normally it would
# clean up any resources it has allocated, but this test doesn't care.

sub _stop {
  my $object = $_[OBJECT];
  print "+ client $object->{'name'} stopped\n";
}

#------------------------------------------------------------------------------
# This is a cheezy hack to keep the session alive while it waits for
# the lock daemon to respond.  All it does is wake up every ten
# seconds and set another alarm.

sub timer_loop {
  my ($object, $kernel) = @_[OBJECT, KERNEL];
  print "*** client $object->{'name'} alarm rang\n";
  $kernel->delay('timer_loop', 10);
}

#------------------------------------------------------------------------------
# Attempt to acquire a lock.

sub acquire_lock {
  my ($object, $kernel) = @_[OBJECT, KERNEL];

  print "??? client $object->{'name'} attempting to acquire lock...\n";
                                        # retry after waiting a little while
  $kernel->delay('acquire_lock', 10);
                                        # uses the lock daemon's protocol
  $kernel->post('lockd', 'lock',
                'lock name', 'perform_locked_operation', 'retry_acquire'
               );
}

#------------------------------------------------------------------------------
# Acquire failed.  Wait one second and retry.

sub retry_acquire {
  my ($object, $kernel) = @_[OBJECT, KERNEL];
  print "--- client $object->{'name'} acquire failed... retrying...\n";
  $kernel->delay('acquire_lock', 1);
}

#------------------------------------------------------------------------------
# Attempt to release a held lock.

sub release_lock {
  my ($object, $kernel) = @_[OBJECT, KERNEL];

  print "??? client $object->{'name'} attempting to release lock...\n";

                                        # retry after waiting a little while
  $kernel->delay('release_lock', 10);

  $kernel->post('lockd', 'unlock',
                'lock name', 'perform_unlocked_operation', 'retry_release'
               );
}

#------------------------------------------------------------------------------
# Release failed.  Wait one second and retry.

sub retry_release {
  my ($object, $kernel) = @_[OBJECT, KERNEL];
  print "--- client $object->{'name'} release failed... retrying...\n";
  $kernel->delay('release_lock', 1);
}

#------------------------------------------------------------------------------
# Do something while holding the lock.

sub perform_locked_operation {
  my ($object, $kernel) = @_[OBJECT, KERNEL];
                                        # clear the alarm!
  $kernel->delay('acquire_lock');
  print "+++ client $object->{'name'} acquired lock... processing...\n";
  $kernel->delay('release_lock', 1);
}

#------------------------------------------------------------------------------
# Do something while not holding the lock.

sub perform_unlocked_operation {
  my ($object, $kernel) = @_[OBJECT, KERNEL];
                                        # clear the alarm!
  $kernel->delay('release_lock');
  print "+++ client $object->{'name'} released lock... processing...\n";
  $kernel->delay('acquire_lock', 1);
}

#==============================================================================
# Create the lock daemon and five clients.  Run them until someone
# sends a SIGINT.

package main;
                                        # start the lock daemon
LockDaemon->new();
                                        # start the clients
foreach (1..5) { LockClient->new($_); }
                                        # run until it's time to stop
$poe_kernel->run();

exit;
