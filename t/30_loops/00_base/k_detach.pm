#!/usr/bin/perl -w
# $Id$

# Tests session detaching.

use strict;
use lib qw(./mylib ../mylib);

# Trace output local to this test program.
sub DEBUG () { 0 }

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More tests => 9;

use POE;

# Moved "global" test accumulation variables out of the "main" session
# because it was becoming a peer to the others that had been detached.
# Sometimes "main" would be stopped before the others, and the program
# would fail when they tried to post results back to it.

my $test_trace = "";

# Spawn a grandchild.

sub spawn_grandchild {
  my $grandchild_id = shift;

  POE::Session->create(
    inline_states => {
      _start => sub {
        my $kernel = $_[KERNEL];
        $kernel->alias_set( $grandchild_id );
        DEBUG and warn $_[SESSION]->ID, " has started.\n";
      },
      _parent => sub {
        my ($kernel, $old_parent, $new_parent) = @_[KERNEL, ARG0, ARG1];
        my $old_alias = $kernel->call($old_parent, "get_alias");
        my $new_alias;
        if (ref($new_parent) eq 'POE::Kernel') {
          $new_alias = 'kernel';
        }
        else {
          $new_alias = $kernel->call($new_parent, "get_alias");
        }
        $test_trace .= "(p $grandchild_id $old_alias $new_alias)";
      },
      _child => sub {
        my ($kernel, $op, $child) = @_[KERNEL, ARG0, ARG1];
        my $child_alias = $kernel->call($child, 'get_alias' );
        $test_trace .= "(c $grandchild_id $op $child_alias)";
      },
      get_alias => sub {
        return $grandchild_id;
      },
      detach_self => sub {
        $_[KERNEL]->detach_myself();
      },
      detach_child => sub {
        $_[KERNEL]->detach_child( $_[ARG0] );
      },
      _stop => sub {
        my $kernel = $_[KERNEL];
        DEBUG and warn $_[SESSION]->ID, " stopped.\n";
      },
    },
  );

  # To prevent this from returning a session reference.
  undef;
}

# Spawn a child.

sub spawn_child {
  my $child_id = shift;
  my $alias = "a$child_id";

  POE::Session->create(
    inline_states => {
      _start => sub {
        my $kernel = $_[KERNEL];
        $kernel->alias_set( $alias );
        $kernel->yield( 'spawn_grandchildren' );
        DEBUG and warn $_[SESSION]->ID, " has started.\n";
      },
      spawn_grandchildren => sub {
        spawn_grandchild( $alias . "_1" );
        spawn_grandchild( $alias . "_2" );
        spawn_grandchild( $alias . "_3" );
      },
      _parent => sub {
        my ($kernel, $old_parent, $new_parent) = @_[KERNEL, ARG0, ARG1];
        my $old_alias = $kernel->call($old_parent, 'get_alias');
        my $new_alias;
        if (ref($new_parent) eq 'POE::Kernel') {
          $new_alias = 'kernel';
        }
        else {
          $new_alias = $kernel->call($new_parent, 'get_alias');
        }
        $test_trace .= "(p $child_id $old_alias $new_alias)";
      },
      _child => sub {
        my ($kernel, $op, $child) = @_[KERNEL, ARG0, ARG1];
        my $child_alias = $kernel->call($child, 'get_alias' );
        $test_trace .= "(c $child_id $op $child_alias)";
      },
      get_alias => sub {
        return $child_id;
      },
      detach_self => sub {
        my $kernel = $_[KERNEL];
        $kernel->detach_myself();
      },
      detach_child => sub {
        my $kernel = $_[KERNEL];
        $kernel->detach_child( $_[ARG0] );
      },
      _stop => sub {
        my $kernel = $_[KERNEL];
        DEBUG and warn $_[SESSION]->ID, " has stopped.\n";
      },
    },
  );

  # To prevent this from returning a session reference.
  undef;
}

# Spawn the main session.  This will spawn children, which will spawn
# grandchildren.  Then the main session will perform controlled
# detaches and watch the results.

POE::Session->create(
  inline_states => {
    _start => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];
      $heap->{idle_count} = 0;
      $kernel->alias_set( 'main' );
      $kernel->yield( 'spawn_children' );
      DEBUG and warn $_[SESSION]->ID, " has started.\n";
    },
    spawn_children => sub {
      my $kernel = $_[KERNEL];
      spawn_child( 1 );
      spawn_child( 2 );
      spawn_child( 3 );
      $kernel->delay( run_tests => 0.5 );
    },
    get_alias => sub {
      return 'main';
    },
    detach_self => sub {
      my $kernel = $_[KERNEL];
      $kernel->detach_myself();
    },
    detach_child => sub {
      my $kernel = $_[KERNEL];
      $kernel->detach_child( $_[ARG0] );
    },
    run_tests => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];

      $test_trace = "";
      $kernel->call( a1_1 => 'detach_self' );
      is(
        $test_trace, '(c 1 lose a1_1)(p a1_1 1 kernel)',
        "a1_1 detached itself"
      );

      $test_trace = '';
      $kernel->call( a2_1 => 'detach_self' );
      is(
        $test_trace, '(c 2 lose a2_1)(p a2_1 2 kernel)',
        "a2_1 detached itself"
      );

      $test_trace = '';
      $kernel->call( a3_1 => 'detach_self' );
      is(
        $test_trace, '(c 3 lose a3_1)(p a3_1 3 kernel)',
        "a3_1 detached itself"
      );

      $test_trace = '';
      $kernel->call( a1 => detach_child => 'a1_2' );
      is(
        $test_trace, '(c 1 lose a1_2)(p a1_2 1 kernel)',
        "a1 detached child a1_2"
      );

      $test_trace = '';
      $kernel->call( a2 => detach_child => 'a2_2' );
      is(
        $test_trace, '(c 2 lose a2_2)(p a2_2 2 kernel)',
        "a2 detached child a2_2"
      );

      $test_trace = '';
      $kernel->call( a3 => detach_child => 'a3_2' );
      is(
        $test_trace, '(c 3 lose a3_2)(p a3_2 3 kernel)',
        "a3 detached child a3_2"
      );

      $test_trace = '';
      $kernel->call( a1 => 'detach_self' );
      is(
        $test_trace, '(c main lose 1)(p 1 main kernel)',
        "a1 detached itself"
      );

      $test_trace = '';
      $kernel->call( main => detach_child => 'a2' );
      is(
        $test_trace, '(c main lose 2)(p 2 main kernel)',
        "a2 detached itself"
      );
    },
    _parent => sub {
      my $old_alias = $_[KERNEL]->call( $_[ARG0], 'get_alias' );
      my $new_alias;
      if (ref($_[ARG1]) eq 'POE::Kernel') {
        $new_alias = 'kernel';
      }
      else {
        $new_alias = $_[KERNEL]->call( $_[ARG1], 'get_alias' );
      }

      $test_trace .= "(p main $old_alias $new_alias)";
    },
    _child => sub {
      my $child_alias = $_[KERNEL]->call( $_[ARG1], 'get_alias' );
      $test_trace .= "(c main $_[ARG0] $child_alias)";
    },
    _stop => sub {
      DEBUG and warn $_[SESSION]->ID, " has stopped.\n";
    },
    grandchild_parent => sub {
      my $old_alias = $_[KERNEL]->call( $_[ARG1], 'get_alias' );
      my $new_alias;
      if (ref($_[ARG2]) eq 'POE::Kernel') {
        $new_alias = 'kernel';
      }
      else {
        $new_alias = $_[KERNEL]->call( $_[ARG2], 'get_alias' );
      }
      $test_trace .= "(p $_[ARG0] $old_alias $new_alias)";
    },
    grandchild_child => sub {
      my $child_alias = $_[KERNEL]->call( $_[ARG2], 'get_alias' );
      $test_trace .= "(c $_[ARG0] $_[ARG1] $child_alias)";
    },
  },
);

POE::Kernel->run();

# Final test to see if the remaining sessions died properly.  The
# trace string can be nondeterministic.  Split it, sort it, and rejoin
# it so it's always in a known order.

substr($test_trace, 0, 1) = '';
substr($test_trace, -1, 1) = '';
$test_trace = '(' . (join ')(', sort split /\)\(/, $test_trace) . ')';

is(
  $test_trace,
  join(
    "",
    "(c 1 lose a1_3)",
    "(c 2 lose a2_3)",
    "(c 3 lose a3_3)",
    "(c main lose 2)",
    "(c main lose 3)",
    "(p 2 main kernel)"
  ),
  "session destruction order"
);

1;
