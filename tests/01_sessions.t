#!/usr/bin/perl -w
# $Id$

# Tests basic compilation and events.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(29);

# Turn on all asserts.
# sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Session::ASSERT_STATES () { 0 }
use POE;

### Test parameters and results.

my $machine_count  = 10;
my $event_count    = 5;
my $sigalrm_caught = 0;
my $sigpipe_caught = 0;
my $sender_count   = 0;
my $got_heap_count = 0;
my $default_count  = 0;
my $get_active_session_within = 0;
my $get_active_session_before = 0;
my $get_active_session_after  = 0;
my $get_active_session_heap   = 0;

die "machine count must be even" if $machine_count & 1;

### Status registers for each state machine instance.

my ( @completions, @objpack );

#------------------------------------------------------------------------------
# Define a simple state machine.

sub task_start {
  my ($kernel, $session, $heap, $id) = @_[KERNEL, SESSION, HEAP, ARG0];
  $heap->{count} = 0;
  $kernel->yield( count => $id );
}

sub task_run {
  my ($kernel, $session, $heap, $id) = @_[KERNEL, SESSION, HEAP, ARG0];

  $sender_count++ if $_[SENDER] == $session;

  if ($heap->{count} & 1) {
    $kernel->yield( bogus => $id ); # _default
  }
  else {
    $kernel->post( $session, bogus => $id ); # _default
  }

  if ( $kernel->call( $session, next_count => $id ) < $event_count ) {

    if ($heap->{count} & 1) {
      $kernel->yield( count => $id );
    }
    else {
      $kernel->post( $session, count => $id );
    }

  }
  else {
    $heap->{id} = $id;
  }
}

sub task_default {
  return 0 if $_[ARG0] eq '_signal'; # ignore signals
  $default_count++ if $_[STATE] eq '_default';
}

sub task_next_count {
  my ($kernel, $session, $heap, $id) = @_[KERNEL, SESSION, HEAP, ARG0];
  ++$heap->{count};
}

sub task_stop {
  $completions[$_[HEAP]->{id}] = $_[HEAP]->{count};
  $got_heap_count++
    if ( defined($_[HEAP]->{got_heap}) and
         $_[HEAP]->{got_heap} == $_[HEAP]->{id}
       );
}

#------------------------------------------------------------------------------
# Test simple signals.

# Spawn a quick state machine to test signals.  This is a classic
# example of inline states being just that: inline anonymous coderefs.
# It makes quick hacks quicker!
POE::Session->create
  ( inline_states =>
    { _start =>
      sub {
        $_[HEAP]->{kills_to_go} = $event_count;
        $_[KERNEL]->sig( ALRM => 'sigalrm_target' );
        $_[KERNEL]->sig( PIPE => 'sigpipe_target' );
        $_[KERNEL]->delay( fire_signals => 0.5 );
      },
      fire_signals =>
      sub {
        if ($_[HEAP]->{kills_to_go}--) {
          $_[KERNEL]->delay( fire_signals => 0.5 );
          if ($^O eq 'MSWin32') {
            $_[KERNEL]->signal( $_[KERNEL], 'ALRM' );
            $_[KERNEL]->signal( $_[KERNEL], 'PIPE' );
          }
          else {
            kill ALRM => $$;
            kill PIPE => $$;
          }
        }
        # One last timer so the session lingers long enough to catch
        # the final signal.
        else {
          $_[KERNEL]->delay( nonexistent_state => 1 );
        }
      },
      sigalrm_target =>
      sub {
        $sigalrm_caught++ if $_[ARG0] eq 'ALRM';
        $_[KERNEL]->sig_handled();
      },
      sigpipe_target =>
      sub {
        $sigpipe_caught++ if $_[ARG0] eq 'PIPE';
        $_[KERNEL]->sig_handled();
      },
    }
  );

# Spawn ten state machines.
for (my $i=0; $i<$machine_count; $i++) {

  # Odd instances, try POE::Session->create
  if ($i & 1) {
    POE::Session->create
      ( inline_states =>
        { _start     => \&task_start,
          _stop      => \&task_stop,
          count      => \&task_run,
          next_count => \&task_next_count,
          _default   => \&task_default,
        },
        args => [ $i ],
        heap => { got_heap => $i },
      );
  }

  # Even instances, try POE::Session->new
  else {
    POE::Session->new
      ( _start     => \&task_start,
        _stop      => \&task_stop,
        count      => \&task_run,
        next_count => \&task_next_count,
        [ $i ],
      );
  }
}

#------------------------------------------------------------------------------
# Simple client/server sessions using events as inter-session
# communications.  Tests postbacks, too.

POE::Session->create
  ( inline_states =>
    { _start =>
      sub {
        $_[KERNEL]->alias_set( 'server' );
        $_[HEAP]->{response} = 0;
      },
      query =>
      sub {
        $_[ARG0]->( ++$_[HEAP]->{response} );
      },
    },
  );

# A simple client session.  It requests five counts and then stops.
# Its magic is that it passes a postback for the response.

my $postback_test = 1;

POE::Session->create
  ( inline_states =>
    { _start =>
      sub {
        $_[KERNEL]->yield( 'query' );
        $_[HEAP]->{cookie} = 0;
      },
      query =>
      sub {
        $_[KERNEL]->post( server =>
                          query =>
                          $_[SESSION]->postback( response =>
                                                 ++$_[HEAP]->{cookie}
                                               )
                        );
      },
      response =>
      sub {
        $postback_test = 0 if $_[ARG0]->[0] != $_[ARG1]->[0];
        if ($_[HEAP]->{cookie} < 5) {
          $_[KERNEL]->yield( 'query' );
        }
      },
      _stop =>
      sub {
        $get_active_session_within =
          ($_[KERNEL]->get_active_session() == $_[SESSION]);
        $get_active_session_heap =
          ($_[KERNEL]->get_active_session()->get_heap() == $_[HEAP]);
      },
    }
  );

#------------------------------------------------------------------------------
# Unmapped package session.

package UnmappedPackage;
use POE::Session; # for constants

sub _start {
  $_[KERNEL]->yield( 'count' );
  $_[HEAP]->{count} = 0;
  $_[HEAP]->{id} = $_[ARG0];
}

sub count {
  return unless $_[OBJECT] eq __PACKAGE__;
  $_[KERNEL]->yield( 'count' ) if ++$_[HEAP]->{count} < $event_count;
}

sub _stop {
  $objpack[$_[HEAP]->{id}] = $_[HEAP]->{count};
}

#------------------------------------------------------------------------------
# Unmapped object session.

package UnmappedObject;
use POE::Session; # for constants

# Trivial constructor.
sub new { bless [ ], shift; }

sub _start {
  $_[KERNEL]->yield( 'count' );
  $_[HEAP]->{count} = 0;
  $_[HEAP]->{id} = $_[ARG0];
}

sub count {
  return unless ref($_[OBJECT]) eq __PACKAGE__;
  $_[KERNEL]->yield( 'count' ) if ++$_[HEAP]->{count} < $event_count;
}

sub _stop {
  $objpack[$_[HEAP]->{id}] = $_[HEAP]->{count};
}

#------------------------------------------------------------------------------
# Unmapped package session.

package MappedPackage;
use POE::Session; # for constants

sub my_start {
  $_[KERNEL]->yield( 'count' );
  $_[HEAP]->{count} = 0;
  $_[HEAP]->{id} = $_[ARG0];
}

sub my_count {
  return unless $_[OBJECT] eq __PACKAGE__;
  $_[KERNEL]->yield( 'count' ) if ++$_[HEAP]->{count} < $event_count;
}

sub my_stop {
  $objpack[$_[HEAP]->{id}] = $_[HEAP]->{count};
}

#------------------------------------------------------------------------------
# Unmapped object session.

package MappedObject;
use POE::Session; # for constants

# Trivial constructor.
sub new { bless [ ], shift; }

sub my_start {
  $_[KERNEL]->yield( 'count' );
  $_[HEAP]->{count} = 0;
  $_[HEAP]->{id} = $_[ARG0];
}

sub my_count {
  return unless ref($_[OBJECT]) eq __PACKAGE__;
  $_[KERNEL]->yield( 'count' ) if ++$_[HEAP]->{count} < $event_count;
}

sub my_stop {
  $objpack[$_[HEAP]->{id}] = $_[HEAP]->{count};
}

#------------------------------------------------------------------------------
# Test the Package and Object sessions.

package main;

# New style (create) object session without event to method name map.
POE::Session->create
  ( object_states =>
    [ UnmappedObject->new => [ '_start', 'count', '_stop' ],
    ],
    args => [ 0 ],
  );

# New style (create) object session with event to method name map.
POE::Session->create
  ( object_states =>
    [ MappedObject->new => { _start => 'my_start',
                             count  => 'my_count',
                             _stop  => 'my_stop',
                           },
    ],
    args => [ 1 ],
  );

# Old style (new) object session without event to method name map.
POE::Session->new
  ( [ 2 ],
    UnmappedObject->new => [ '_start', 'count', '_stop' ],
  );

# Old style (new) object session with event to method name map.
POE::Session->new
  ( [ 3 ],
    MappedObject->new => { _start => 'my_start',
                           count  => 'my_count',
                           _stop  => 'my_stop',
                         },
  );

# New style (create) package session without event to method name map.
POE::Session->create
  ( package_states =>
    [ UnmappedPackage => [ '_start', 'count', '_stop' ],
    ],
    args => [ 4 ],
  );

# New style (create) package session with event to method name map.
POE::Session->create
  ( package_states =>
    [ MappedPackage => { _start => 'my_start',
                         count  => 'my_count',
                         _stop  => 'my_stop',
                       },
    ],
    args => [ 5 ],
  );

# Old style (new) package session without event to method name map.
POE::Session->new
  ( [ 6 ],
    UnmappedPackage => [ '_start', 'count', '_stop' ],
  );

# Old style (new) package session with event to method name map.
POE::Session->new
  ( [ 7 ],
    MappedPackage => { _start => 'my_start',
                       count  => 'my_count',
                       _stop  => 'my_stop',
                     },
  );

#------------------------------------------------------------------------------
# Main loop.

$get_active_session_before = $poe_kernel->get_active_session() == $poe_kernel;
$poe_kernel->run();
$get_active_session_after = $poe_kernel->get_active_session() == $poe_kernel;

#------------------------------------------------------------------------------
# Final tests.

# Now make sure they've run.
for (my $i=0; $i<$machine_count; $i++) {
  print 'not ' unless $completions[$i] == $event_count;
  print 'ok ', $i+1, "\n";
}

# Were all the signals caught?
if ($^O eq 'MSWin32') {
  print "ok 11 # skipped: Windows doesn't support signals\n";
  print "ok 12 # skipped: Windows doesn't support signals\n";
}
else {
  print 'not ' unless $sigalrm_caught == $event_count;
  print "ok 11\n";

  print 'not ' unless $sigpipe_caught == $event_count;
  print "ok 12\n";
}

# Did the postbacks work?
print 'not ' unless $postback_test;
print "ok 13\n";

# Were the various get_active_session() calls correct?
print 'not ' unless $get_active_session_within;
print "ok 14\n";

print 'not ' unless $get_active_session_before;
print "ok 15\n";

print 'not ' unless $get_active_session_after;
print "ok 16\n";

# Was the get_heap() call correct?
print 'not ' unless $get_active_session_heap;
print "ok 17\n";

# Gratuitous tests to appease the coverage gods.
print 'not ' unless
  ( ARG1 == ARG0+1 and ARG2 == ARG1+1 and ARG3 == ARG2+1 and
    ARG4 == ARG3+1 and ARG5 == ARG4+1 and ARG6 == ARG5+1 and
    ARG7 == ARG6+1 and ARG8 == ARG7+1 and ARG9 == ARG8+1
  );
print "ok 18\n";

print 'not ' unless $sender_count == $machine_count * $event_count;
print "ok 19\n";

print 'not ' unless $default_count == ($machine_count * $event_count) / 2;
print "ok 20\n";

print 'not ' unless $got_heap_count == $machine_count / 2;
print "ok 21\n";

# Object/package sessions.
for (0..7) {
  print 'not ' unless $objpack[$_] == $event_count;
  print 'ok ', $_ + 22, "\n";
}

exit;

