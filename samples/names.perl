#!perl -w -I..
# $Id$

# Tests named "daemon" sessions by setting up a lock service session
# and some client to exercise it.  When all the client sessions exit,
# the Kernel should clean up the daemons and die peacefully.  Also
# uses objects for state machines, which is cool in its own right.

use strict;
use POE;

#------------------------------------------------------------------------------
# A "lock" server.  Why not?

package LockDaemon;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { }, $type;
  print "> $self created\n";
  new POE::Session($kernel, $self, [ qw(_start _stop lock unlock sighandler)
                                   ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "< $self destroyed\n";
}

sub _start {
  my ($object, $kernel, $namespace) = @_;
  $kernel->alias_set('lockd');
  $kernel->sig('INT', 'sighandler');
  $kernel->sig('ZOMBIE', 'sighandler');
  print "+ lockd started.\n";
}

sub sighandler {
  my ($object, $kernel, $namespace, $sender, $signal_name) = @_;
  print "@ lockd caught and handled SIG$signal_name\n";
  return 1;
}

sub _stop {
  my ($object, $kernel, $namespace) = @_;
  $kernel->alias_remove('lockd');
  print "- lockd stopped.\n";
}

sub lock {
  my ($object, $kernel, $namespace, $sender, $lock_name, $success, $fail) = @_;

  if (exists $namespace->{$lock_name}) {
                                        # check existing info
    my ($owners, $time) = 
    my ($owner, $time) = @{$namespace->{$lock_name}};
                                        # same owner?  refresh lock time
    if ($owner eq $sender) {
      $namespace->{$lock_name}->[1] = time();
      $kernel->post($sender, $success);
      return 0;
    }
                                        # different owner?  fail
    $kernel->post($sender, $fail);
    return 0;
  }
                                        # no lock?  add one
  $namespace->{$lock_name} = [ $sender, time() ];
  $kernel->post($sender, $success);
}

sub unlock {
  my ($object, $kernel, $namespace, $sender, $lock_name, $success, $fail) = @_;

  if (exists $namespace->{$lock_name}) {
    my ($owner, $time) = @{$namespace->{$lock_name}};
    if ($owner eq $sender) {
      delete $namespace->{$lock_name};
      $kernel->post($sender, $success);
      return 0;
    }
  }
  $kernel->post($sender, $fail);
  return 0;
}

#------------------------------------------------------------------------------
# A client that wants to lock things.

package LockClient;

sub new {
  my ($type, $kernel, $name) = @_;
  my $self = bless { 'name' => $name }, $type;
  print "> $self created\n";
  new POE::Session($kernel, $self,
                   [ qw(_start _stop
                        timer_loop
                        acquire_lock retry_acquire
                        release_lock retry_release
                        perform_locked_operation perform_unlocked_operation
                       )
                   ]
                  );
  undef;
}

sub DESTROY {
  my $self = shift;
  print "< $self destroyed\n";
}

sub _start {
  my ($object, $kernel, $namespace) = @_;
  $kernel->delay('timer_loop', 1);
  $kernel->post($namespace, 'perform_unlocked_operation');
  print "+ client $object->{'name'} started\n";
}

sub _stop {
  my ($object, $kernel, $namespace) = @_;
  print "+ client $object->{'name'} stopped\n";
}
                                        # cheezy hack to keep us alive
sub timer_loop {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "*** client $object->{'name'} alarm rang\n";
  $kernel->delay('timer_loop', 10);
}

sub acquire_lock {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "??? client $object->{'name'} attempting to acquire lock...\n";
  $kernel->post('lockd', 'lock',
                'lock name', 'perform_locked_operation', 'retry_acquire'
               );
}

sub retry_acquire {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "--- client $object->{'name'} acquire failed... retrying...\n";
  $kernel->delay('acquire_lock', 1);
}

sub release_lock {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "??? client $object->{'name'} attempting to release lock...\n";
  $kernel->post('lockd', 'unlock',
                'lock name', 'perform_unlocked_operation', 'retry_release'
               );
}

sub retry_release {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "--- client $object->{'name'} release failed... retrying...\n";
  $kernel->delay('release_lock', 1);
}

sub perform_locked_operation {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "+++ client $object->{'name'} acquired lock... processing...\n";
  $kernel->delay('release_lock', 1);
}

sub perform_unlocked_operation {
  my ($object, $kernel, $namespace, $sender) = @_;
  print "+++ client $object->{'name'} released lock... processing...\n";
  $kernel->delay('acquire_lock', 1);
}

#------------------------------------------------------------------------------

package main;

my $kernel = new POE::Kernel;
                                        # start a lock daemon
new LockDaemon($kernel);
                                        # start some clients
foreach (1..5) {
  new LockClient($kernel, $_);
}
                                        # run the whole mess
$kernel->run();

exit;
