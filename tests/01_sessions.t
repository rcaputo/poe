#!/usr/bin/perl -w
# $Id$

# Tests basic compilation and events.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(25);

# Turn on all asserts.
#sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

### Test parameters and results.

my $machine_count  = 10;
my $event_count    = 10;
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

my @completions;

### Define a simple state machine.

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

### Main loop.

print "ok 1\n";

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
        $_[KERNEL]->delay( fire_signals => 1 );
      },
      fire_signals =>
      sub {
        if ($_[HEAP]->{kills_to_go}--) {
          $_[KERNEL]->delay( fire_signals => 1 );
          kill ALRM => $$;
          kill PIPE => $$;
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
      },
      sigpipe_target =>
      sub {
        $sigpipe_caught++ if $_[ARG0] eq 'PIPE';
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

print "ok 2\n";

# A simple service session.  It returns an ever increasing count.

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

print "ok 3\n";

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

print "ok 4\n";

$get_active_session_before = $poe_kernel->get_active_session() == $poe_kernel;

# Now run them 'til they complete.
$poe_kernel->run();

$get_active_session_after = $poe_kernel->get_active_session() == $poe_kernel;

# Now make sure they've run.
for (my $i=0; $i<$machine_count; $i++) {
  print 'not ' unless $completions[$i] == $event_count;
  print 'ok ', $i+5, "\n";
}

# Were all the signals caught?
print 'not ' unless $sigalrm_caught == $event_count;
print "ok 15\n";

print 'not ' unless $sigpipe_caught == $event_count;
print "ok 16\n";

# Did the postbacks work?
print 'not ' unless $postback_test;
print "ok 17\n";

# Were the various get_active_session() calls correct?
print 'not ' unless $get_active_session_within;
print "ok 18\n";

print 'not ' unless $get_active_session_before;
print "ok 19\n";

print 'not ' unless $get_active_session_after;
print "ok 20\n";

# Was the get_heap() call correct?
print 'not ' unless $get_active_session_heap;
print "ok 21\n";

# Gratuitous tests to appease the coverage gods.
print 'not ' unless
  ( ARG1 == ARG0+1 and ARG2 == ARG1+1 and ARG3 == ARG2+1 and
    ARG4 == ARG3+1 and ARG5 == ARG4+1 and ARG6 == ARG5+1 and
    ARG7 == ARG6+1 and ARG8 == ARG7+1 and ARG9 == ARG8+1
  );
print "ok 22\n";

print 'not ' unless $sender_count == $machine_count * $event_count;
print "ok 23\n";

print 'not ' unless $default_count == ($machine_count * $event_count) / 2;
print "ok 24\n";

print 'not ' unless $got_heap_count == $machine_count / 2;
print "ok 25\n";

exit;

