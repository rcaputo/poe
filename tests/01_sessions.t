#!/usr/bin/perl -w
# $Id$

# Tests basic compilation and events.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(17);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

### Test parameters.

my $machine_count  = 10;
my $event_count    = 10;
my $signals_caught = 0;

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

sub task_next_count {
  my ($kernel, $session, $heap, $id) = @_[KERNEL, SESSION, HEAP, ARG0];
  ++$heap->{count};
}

sub task_stop {
  $completions[$_[HEAP]->{id}] = $_[HEAP]->{count};
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
        $_[KERNEL]->sig( USR1 => 'sigusr1_target' );
        $_[KERNEL]->delay( fire_sigusr1 => 1 );
      },
      fire_sigusr1 =>
      sub {
        if ($_[HEAP]->{kills_to_go}--) {
          $_[KERNEL]->delay( fire_sigusr1 => 1 );
          kill USR1 => $$;
        }
        # One last timer so the session lingers long enough to catch
        # the final signal.
        else {
          $_[KERNEL]->delay( nonexistent_state => 1 );
        }
      },
      sigusr1_target =>
      sub {
        $signals_caught++ if $_[ARG0] eq 'USR1';
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
        },
        args => [ $i ],
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
    }
  );

print "ok 4\n";

# The coverage testing runtime tracker hangs this test.  We override
# POE's SIGINT and SIGALRM handlers so that it can at least exit
# gracefully once the tests are done.
if ($^P) {
  $SIG{ALRM} = $SIG{INT} = sub { exit; };
  alarm(60);
}

# Now run them 'til they complete.
$poe_kernel->run();

# Now make sure they've run.
for (my $i=0; $i<$machine_count; $i++) {
  print 'not ' unless $completions[$i] == $event_count;
  print 'ok ', $i+5, "\n";
}

# Were all the signals caught?
print 'not ' unless $signals_caught == $event_count;
print "ok 15\n";

# Did the postbacks work?
print 'not ' unless $postback_test;
print "ok 16\n";

print "ok 17\n";

exit;
