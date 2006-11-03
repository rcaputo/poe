#!/usr/bin/perl -w
# $Id$

# Tests basic compilation and events.

use strict;

use lib qw(./mylib ../mylib);

BEGIN {
  sub POE::Kernel::ASSERT_DEFAULT () { 1 }
  sub POE::Kernel::TRACE_DEFAULT  () { 1 }
  sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }
}

use Test::More tests => 44;
use POE;

### Test parameters and results.

my $machine_count  = 10;
my $event_count    = 5;
my $sigalrm_caught = 0;
my $sigpipe_caught = 0;
my $sender_count   = 0;
my $got_heap_count = 0;
my $default_count  = 0;

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
  $got_heap_count++ if (
    defined($_[HEAP]->{got_heap}) and
    $_[HEAP]->{got_heap} == $_[HEAP]->{id}
  );
}

#------------------------------------------------------------------------------
# Test simple signals.

# Spawn a quick state machine to test signals.  This is a classic
# example of inline states being just that: inline anonymous coderefs.
# It makes quick hacks quicker!
POE::Session->create(
  inline_states => {
    _start => sub {
      $_[HEAP]->{kills_to_go} = $event_count;
      $_[KERNEL]->sig( ALRM => 'sigalrm_target' );
      $_[KERNEL]->sig( PIPE => 'sigpipe_target' );
      $_[KERNEL]->delay( fire_signals => 0.5 );
    },
    fire_signals => sub {
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
        $_[KERNEL]->delay( done_waiting => 1 );
      }
    },
    sigalrm_target => sub {
      $sigalrm_caught++ if $_[ARG0] eq 'ALRM';
      $_[KERNEL]->sig_handled();
    },
    sigpipe_target => sub {
      $sigpipe_caught++ if $_[ARG0] eq 'PIPE';
      $_[KERNEL]->sig_handled();
    },
    done_waiting => sub {
      $_[KERNEL]->sig( ALRM => undef );
      $_[KERNEL]->sig( PIPE => undef );
    },
  }
);

# Spawn ten state machines.
for (my $i=0; $i<$machine_count; $i++) {

  POE::Session->create(
    inline_states => {
      _start     => \&task_start,
      _stop      => \&task_stop,
      count      => \&task_run,
      next_count => \&task_next_count,
      _default   => \&task_default,
    },
    args => [ $i ],
    heap => { got_heap => $i },
  );
}

#------------------------------------------------------------------------------
# Simple client/server sessions using events as inter-session
# communications.  Tests postbacks, too.

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->alias_set( 'server' );
      $_[HEAP]->{response} = 0;
    },
    sync_query => sub {
      $_[ARG0]->( ++$_[HEAP]->{response} );
    },
    query => sub {
      $_[ARG0]->( ++$_[HEAP]->{response} );
    },
  },
);

# A simple client session.  It requests five counts and then stops.
# Its magic is that it passes a postback for the response.

my $postback_test = 1;
my $callback_test = 1;

POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->yield( 'query' );
      $_[HEAP]->{cookie} = 0;
    },
    query => sub {
      $_[KERNEL]->post(
        server =>
        query  => $_[SESSION]->postback(response => ++$_[HEAP]->{cookie})
      );
      $_[HEAP]->{sync_called_back} = 0;
      $_[KERNEL]->call(
        server     =>
        sync_query =>
        $_[SESSION]->callback(sync_response => ++$_[HEAP]->{cookie})
      );
      $callback_test = 0 unless $_[HEAP]->{sync_called_back};
    },
    sync_response => sub {
      my ($req, $rsp) = ($_[ARG0]->[0], $_[ARG1]->[0] + 1);
      $callback_test = 0 unless $req == $rsp;
      $_[HEAP]->{sync_called_back} = 1;
    },
    response => sub {
      my ($req, $rsp) = ($_[ARG0]->[0], $_[ARG1]->[0] - 1);
      $postback_test = 0 unless $req == $rsp;
      if ($_[HEAP]->{cookie} < 5) {
        $_[KERNEL]->yield( 'query' );
      }
    },
    _stop => sub {
      ok(
        $_[KERNEL]->get_active_session() == $_[SESSION],
        "get_active_session within session"
      );
      ok(
        $_[KERNEL]->get_active_session()->get_heap() == $_[HEAP],
        "get_heap during stop"
      );
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
POE::Session->create(
  object_states => [
    UnmappedObject->new() => [ '_start', 'count', '_stop' ],
  ],
  args => [ 0 ],
);

# New style (create) object session with event to method name map.
POE::Session->create(
  object_states => [
    MappedObject->new => {
      _start => 'my_start',
      count  => 'my_count',
      _stop  => 'my_stop',
    },
  ],
  args => [ 1 ],
);

# New style (create) package session without event to method name map.
POE::Session->create(
  package_states => [
    UnmappedPackage => [ '_start', 'count', '_stop' ],
  ],
  args => [ 2 ],
);

# New style (create) package session with event to method name map.
POE::Session->create(
  package_states => [
    MappedPackage => {
      _start => 'my_start',
      count  => 'my_count',
      _stop  => 'my_stop',
    },
  ],
  args => [ 3 ],
);

#------------------------------------------------------------------------------
# Test changing options
POE::Session->create(
  inline_states => {
    _start => sub {
      my $orig = $_[SESSION]->option(default => 1);
      Test::More::ok($orig, "option original value");
      my $rv = $_[SESSION]->option('default');
      Test::More::ok($rv, "set default option successfully");
      $rv = $_[SESSION]->option('default' => $orig);
      Test::More::ok($rv, "reset default option successfully");
      my $rv = $_[SESSION]->option('default');
      Test::More::ok(!($rv xor $orig), "reset default option successfully");

      $_[KERNEL]->yield("idle");
    },
    idle => sub { },
  },
  options => { default => 1 },
);

#------------------------------------------------------------------------------
# Test deprecation of new(), test invalid arguments to create()
eval { POE::Session->new("foo" => sub { } ) };
ok($@ ne '', "new() is deprecated");

eval { POE::Session->create("an", "odd", "number", "of", "elephants") };
ok($@ ne '', "create() doesn't accept an odd number of args");

#------------------------------------------------------------------------------
# Main loop.

ok(
  $poe_kernel->get_active_session() == $poe_kernel,
  "get_active_session before POE::Kernel->run()"
);

POE::Kernel->run();

ok(
  $poe_kernel->get_active_session() == $poe_kernel,
  "get_active_session after POE::Kernel->run()"
);

#------------------------------------------------------------------------------
# Final tests.

# Now make sure they've run.
for (my $i=0; $i<$machine_count; $i++) {
  ok(
    $completions[$i] == $event_count,
    "test $i ran"
  );
}

# Were all the signals caught?
SKIP: {
  if ($^O eq "MSWin32" or $^O eq "MacOS") {
    skip "$^O does not support signals", 2;
  }

  ok(
    $sigalrm_caught == $event_count,
    "caught enough SIGALRMs"
  );

  ok(
    $sigpipe_caught == $event_count,
    "caught enough SIGPIPEs"
  );
}

# Did the postbacks work?
ok( $postback_test, "postback test" );
ok( $callback_test, "callback test" );

# Gratuitous tests to appease the coverage gods.
ok(
  (ARG1 == ARG0+1) && (ARG2 == ARG1+1) && (ARG3 == ARG2+1) &&
  (ARG4 == ARG3+1) && (ARG5 == ARG4+1) && (ARG6 == ARG5+1) &&
  (ARG7 == ARG6+1) && (ARG8 == ARG7+1) && (ARG9 == ARG8+1),
  "ARG constants are good"
);

ok(
  $sender_count == $machine_count * $event_count,
  "sender_count"
);

ok(
  $default_count == $machine_count * $event_count,
  "default_count"
);

ok(
  $got_heap_count == $machine_count,
  "got_heap_count"
);

# Object/package sessions.
for (0..3) {
  ok(
    $objpack[$_] == $event_count,
    "object/package session $_ event count"
  );
}

my $sessions_destroyed = 0;
my $objects_destroyed = 0;
my $stop_called = 0;
my $parent_called = 0;
my $child_called = 0;

package POE::MySession;

use vars qw(@ISA);

use POE::Session;
@ISA = qw(POE::Session);

sub DESTROY {
  $_[0]->SUPER::DESTROY;
  $sessions_destroyed++;
}

package MyObject;

sub new { bless {} }
sub DESTROY { $objects_destroyed++ }

package main;

POE::MySession->create(
  inline_states => {
    _start => sub {
      $_[HEAP]->{object} = MyObject->new;
      POE::MySession->create(
        inline_states => {
          _start => sub {
            $_[HEAP]->{object} = MyObject->new;
            POE::MySession->create(
              inline_states => {
                _start => sub {
                  $_[HEAP]->{object} = MyObject->new;
                  POE::MySession->create(
                    inline_states => {
                      _start => sub {
                        $_[HEAP]->{object} = MyObject->new;
                        $_[KERNEL]->delay(nonexistent => 3600);
                        $_[KERNEL]->alias_set('test4');
                      },
                      _parent => sub {
                        $parent_called++;
                      },
                      _child => sub { }, # To shush ASSERT
                      _stop => sub {
                        $stop_called++;
                      },
                    },
                  );
                  $_[KERNEL]->delay(nonexistent => 3600);
                  $_[KERNEL]->alias_set('test3');
                },
                _parent => sub {
                  $parent_called++;
                },
                _child => sub {
                  $child_called++ if $_[ARG0] eq 'lose';
                },
                _stop => sub {
                  $stop_called++;
                },
              },
            );
            $_[KERNEL]->delay(nonexistent => 3600);
            $_[KERNEL]->alias_set('test2');
          },
          _parent => sub {
            $parent_called++;
          },
          _child => sub {
            $child_called++ if $_[ARG0] eq 'lose';
          },
          _stop => sub {
            $stop_called++;
          },
        },
      );
      $_[KERNEL]->delay(nonexistent => 3600);
      $_[KERNEL]->alias_set('test1');
      $_[KERNEL]->yield("stop");
    },
    _parent => sub {
      $parent_called++;
    },
    _child => sub {
      $child_called++ if $_[ARG0] eq 'lose';
    },
    _stop => sub {
      $stop_called++;
    },
    stop => sub {
      POE::Kernel->stop();

      my $expected;
      if ($] >= 5.004 and $] < 5.00405) {
        diag( "Note: We find your choice of Perl versions disturbing" );
        diag( "primarily due to the number of bugs POE triggers within" );
        diag( "it.  You should seriously consider upgrading." );
        $expected = 0;
      }
      else {
        $expected = 3;
      }

      ok(
        $sessions_destroyed == $expected,
        "$sessions_destroyed sessions destroyed (expected $expected)"
      );

      # 5.004 and 5.005 have some nasty gc issues. Near as I can tell,
      # data inside the heap is surviving the session DESTROY. This
      # isnt possible in a sane and normal world. So if this is giving
      # you fits, consider it a sign that your "legacy perl" fetish is
      # bizarre and harmful.
      my $expected;
      if ($] >= 5.006 or ($] >= 5.004 and $] < 5.00405)) {
        $expected = 3;
      } else {
        $expected = 2;
        diag( "Your version of Perl is rather buggy.  Consider upgrading." );
      }

      ok(
        $objects_destroyed == $expected,
        "$objects_destroyed objects destroyed (expected $expected)"
      );
    }
  }
);

POE::Kernel->run();

ok(
  $stop_called == 0,
  "_stop wasn't called"
);

ok(
  $child_called == 0,
  "_child wasn't called"
);

ok(
  $parent_called == 0,
  "_parent wasn't called"
);

my $expected;
if ($] >= 5.004 and $] < 5.00405) {
  diag( "Seriously.  We've had to create special cases just to cater" );
  diag( "to your freakish 'legacy buggy perl' fetish.  Consider upgrading" );
  $expected = 0;
}
else {
  $expected = 4;
}

ok(
  $sessions_destroyed == $expected,
  "destroyed $sessions_destroyed sessions (expected $expected)"
);

# 5.004 and 5.005 have some nasty gc issues. Near as I can tell,
# data inside the heap is surviving the session DESTROY. This
# isnt possible in a sane and normal world.
my $expected;
if($] >= '5.006') {
  $expected = 4;
}
elsif ($] == 5.005_04 or $] == 5.004_05) {
  $expected = 3;
  diag( "Here's yet another special test case to work around memory" );
  diag( "leaks in Perl $]." );
}
else {
  $expected = 4;
}

ok(
  $objects_destroyed == $expected,
  "destroyed $objects_destroyed objects (expected $expected)"
);

# This simple session just makes sure we can start another Session and
# another Kernel.  If all goes well, it'll dispatch some events and
# exit normally.

# The restart test dumps core when using Tk with Perl 5.8.0 and
# beyond, but only if they're built without threading support.  It
# happens consistently in a pure Tk test case.  It happens
# consistently in POE's "make test" suite.  It doesn't happen at all
# when running the test by hand.
#
# http://rt.cpan.org/Ticket/Display.html?id=8588 is tracking the Tk
# test case.  Wish us luck there.
#
# Meanwhile, these tests will be skipped under Tk if Perl is 5.8.0 or
# beyond, and it's not built for threading.

SKIP: {
#  use Config;
#  skip "Restarting Tk dumps core in single-threaded perl $]", 6 if (
#    $] >= 5.008 and
#    exists $INC{"Tk.pm"} and
#    !$Config{useithreads}
#  );

  POE::Session->create(
    options => { trace => 1, default => 1, debug => 1 },
    inline_states => {
      _start => sub {
        pass("restarted event loop session _start");
        $_[KERNEL]->yield("woot");
        $_[KERNEL]->delay(narf => 1);
      },
      woot => sub {
        pass("restarted event loop session yield()");
      },
      narf => sub {
        pass("restarted event loop session timer delay()");
      },
      _stop => sub {
        pass("restarted event loop session _stop");
      },
    }
  );

  POE::Kernel->run();
  pass("restarted event loop returned normally");
}

1;
