#!/usr/bin/perl -w
# $Id$

# Tests session detaching.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(9);

# Turn on all asserts.  This makes the tests slower, but it also
# ensures that internal checks are performed within POE::Kernel.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE;

# Spawn a grandchild.

sub spawn_grandchild {
  my $grandchild_id = shift;

  POE::Session->create
    ( inline_states =>
      { _start => sub {
          $_[KERNEL]->alias_set( $grandchild_id );
        },
        _parent => sub {
          $_[KERNEL]->call( main => grandchild_parent =>
                            $grandchild_id, $_[ARG0], $_[ARG1]
                          );
        },
        _child => sub {
          $_[KERNEL]->call( main => grandchild_child =>
                            $grandchild_id, $_[ARG0], $_[ARG1]
                          );
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
      },
    );

  # To prevent this from returning a session reference.
  undef;
}

# Spawn a child.

sub spawn_child {
  my $child_id = shift;
  my $alias = "a$child_id";

  POE::Session->create
    ( inline_states =>
      { _start => sub {
          my $kernel = $_[KERNEL];
          $kernel->alias_set( $alias );
          $kernel->yield( 'spawn_grandchildren' );
        },
        spawn_grandchildren => sub {
          &spawn_grandchild( $alias . "_1" );
          &spawn_grandchild( $alias . "_2" );
          &spawn_grandchild( $alias . "_3" );
        },
        _parent => sub {
          my $kernel = $_[KERNEL];
          $kernel->call( main => child_parent =>
                         $child_id, $_[ARG0], $_[ARG1]
                       );
        },
        _child => sub {
          my ($kernel, $op, $child) = @_[KERNEL, ARG0, ARG1];
          $kernel->call( main => child_child => $child_id, $op, $child );
          undef;
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
      },
    );

  # To prevent this from returning a session reference.
  undef;
}

# Spawn the main session.  This will spawn children, which will spawn
# grandchildren.  Then the main session will perform controlled
# detaches and watch the results.

POE::Session->create
  ( inline_states =>
    { _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];
        $heap->{idle_count} = 0;
        $kernel->alias_set( 'main' );
        $kernel->yield( 'spawn_children' );
        $kernel->sig( IDLE => '_idle' );
      },
      spawn_children => sub {
        my $kernel = $_[KERNEL];
        &spawn_child( 1 );
        &spawn_child( 2 );
        &spawn_child( 3 );
        $kernel->yield( 'run_tests' );
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

        $heap->{test_trace} = '';
        $kernel->call( a1_1 => 'detach_self' );
        ok_if( 1, $heap->{test_trace} eq '(c 1 lose a1_1)(p a1_1 1 kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( a2_1 => 'detach_self' );
        ok_if( 2, $heap->{test_trace} eq '(c 2 lose a2_1)(p a2_1 2 kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( a3_1 => 'detach_self' );
        ok_if( 3, $heap->{test_trace} eq '(c 3 lose a3_1)(p a3_1 3 kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( a1 => detach_child => 'a1_2' );
        ok_if( 4, $heap->{test_trace} eq '(c 1 lose a1_2)(p a1_2 1 kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( a2 => detach_child => 'a2_2' );
        ok_if( 5, $heap->{test_trace} eq '(c 2 lose a2_2)(p a2_2 2 kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( a3 => detach_child => 'a3_2' );
        ok_if( 6, $heap->{test_trace} eq '(c 3 lose a3_2)(p a3_2 3 kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( a1 => 'detach_self' );
        ok_if( 7, $heap->{test_trace} eq '(c main lose 1)(p 1 main kernel)' );

        $heap->{test_trace} = '';
        $kernel->call( main => detach_child => 'a2' );
        ok_if( 8, $heap->{test_trace} eq '(c main lose 2)(p 2 main kernel)' );

        $heap->{test_trace} = '';
      },
      _idle => sub {
        return 1 unless $_[HEAP]->{idle_count}++;
      },
      _stop => sub {
        my $trace = $_[HEAP]->{test_trace};

        # This can be nondeterministic.  Split it, sort it, and rejoin
        # it so it's always in a known order.

        substr($trace, 0, 1) = '';
        substr($trace, -1, 1) = '';
        $trace = '(' . (join ')(', sort split /\)\(/, $trace) . ')';

        ok_if( 9,
               $trace eq
               '(c 1 lose a1_3)(c 2 lose a2_3)(c 3 lose a3_3)(c main lose 3)'
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
        $_[HEAP]->{test_trace} .= "(p main $old_alias $new_alias)";
      },
      _child => sub {
        my $child_alias = $_[KERNEL]->call( $_[ARG1], 'get_alias' );
        $_[HEAP]->{test_trace} .= "(c main $_[ARG0] $child_alias)";
      },
      child_parent => sub {
        my $old_alias = $_[KERNEL]->call( $_[ARG1], 'get_alias' );
        my $new_alias;
        if (ref($_[ARG2]) eq 'POE::Kernel') {
          $new_alias = 'kernel';
        }
        else {
          $new_alias = $_[KERNEL]->call( $_[ARG2], 'get_alias' );
        }
        $_[HEAP]->{test_trace} .= "(p $_[ARG0] $old_alias $new_alias)";
      },
      child_child => sub {
        my $child_alias = $_[KERNEL]->call( $_[ARG2], 'get_alias' );
        $_[HEAP]->{test_trace} .= "(c $_[ARG0] $_[ARG1] $child_alias)";
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
        $_[HEAP]->{test_trace} .= "(p $_[ARG0] $old_alias $new_alias)";
      },
      grandchild_child => sub {
        my $child_alias = $_[KERNEL]->call( $_[ARG2], 'get_alias' );
        $_[HEAP]->{test_trace} .= "(c $_[ARG0] $_[ARG1] $child_alias)";
      },
    },
  );

$poe_kernel->run();

&results;

exit 0;

__END__




# Spawn a main session.  This session spawns some children; some of
# them have their own children (grandchildren of this session), and
# some don't.  Ensure that the _parent/_child events are properly
# fired.

POE::Session->create
  ( inline_states =>
    { _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

#        note_attach($_[SESSION], $_[SENDER]);

        # Flag that we're running the _start handler.  Child lossage
        # during _start counts as detachment.
        $heap->{in_start_state} = 1;

        # Spawn nine child sessions.  Each child session will have a
        # child of its own.

        for my $child_number (1..9) {

          # The first three children detach themselves.

          if ($child_number < 4) {
            my $child_id =
              POE::Session->create
                ( inline_states =>
                  { _start => sub {
#                      note_attach($_[SESSION], $_[SENDER]);

                      my $heap = $_[HEAP];
                      $heap->{in_start_state} = 1;


                      # The first grandchild detaches itself.
                      if ($child_number == 1) {
                        &spawn_self_detacher($child_number . '.' . $child_number);
                      }

                      # The second grandchild is detached by the child.
                      elsif ($child_number == 2) {
                        &spawn_and_detach($child_number . '.' . $child_number);
                      }

                      # The third grandchild sticks around.
                      elsif ($child_number == 3) {
                        &spawn_non_detacher($child_number . '.' . $child_number);
                      }

                      # Self-integrity check.
                      else {
                        die "this should not happen";
                      }

                      $heap->{in_start_state} = 0;
                    },
                    _parent => \&track_parent_change,
                    _child  => \&track_child_change,
                    _stop   => \&track_session_stop,
                  },
                )->ID;

            $child_info[$child_id]->[CHILD_NUMBER] = $child_number;
          }

          # The next three children are detached by the parent.

          elsif ($child_number < 7) {
            my $child_id =
              POE::Session->create
                ( inline_states =>
                  { _start => sub {
#                      note_attach($_[SESSION], $_[SENDER]);

                      my $heap = $_[HEAP];
                      $heap->{in_start_state} = 1;

                      # The first grandchild detaches itself.
                      if ($child_number == 4) {
                        &spawn_self_detacher($child_number . '.' . $child_number);
                      }

                      # The second grandchild is detached by the child.
                      elsif ($child_number == 5) {
                        &spawn_and_detach($child_number . '.' . $child_number);
                      }

                      # The third grandchild sticks around.
                      elsif ($child_number == 6) {
                        &spawn_non_detacher($child_number . '.' . $child_number);
                      }

                      # Self-integrity check.
                      else {
                        die "this should not happen";
                      }

                      $heap->{in_start_state} = 0;
                    },
                    _parent => \&track_parent_change,
                    _child  => \&track_child_change,
                    _stop   => \&track_session_stop,
                  },
                )->ID;

            $child_info[$child_id]->[CHILD_NUMBER] = $child_number;
          }

          # The last three children are not detached.  This is the
          # control group.

          elsif ($child_number < 10) {
            my $child_id =
              POE::Session->create
                ( inline_states =>
                  { _start => sub {
#                      note_attach($_[SESSION], $_[SENDER]);

                      my $heap = $_[HEAP];
                      $heap->{in_start_state} = 1;

                      # The first grandchild detaches itself.
                      if ($child_number == 7) {
                        &spawn_self_detacher($child_number . '.' . $child_number);
                      }

                      # The second grandchild is detached by the child.
                      elsif ($child_number == 8) {
                        &spawn_and_detach($child_number . '.' . $child_number);
                      }

                      # The third grandchild sticks around.
                      elsif ($child_number == 9) {
                        &spawn_non_detacher($child_number . '.' . $child_number);
                      }

                      # Self-integrity check.
                      else {
                        die "this should not happen";
                      }

                      $heap->{in_start_state} = 0;
                    },
                    _parent => \&track_parent_change,
                    _child  => \&track_child_change,
                    _stop   => \&track_session_stop,
                  },
                )->ID;

            $child_info[$child_id]->[CHILD_NUMBER] = $child_number;
          }

          # Self-integrity check.
          else {
            die "this should not happen";
          }
        }

        # All nine children have been created.  Set a flag that
        # indicates the session creation is done.
        $heap->{in_start_state} = 0;
      },

      _parent => \&track_parent_change,
      _child  => \&track_child_change,
      _stop   => \&track_session_stop,
    },
  );

$poe_kernel->run();

for (my $child_id = 0; $child_id < @child_info; $child_id++) {
  my $child = $child_info[$child_id];
  next unless defined $child;

  print( ",----- child ID $child_id -----\n",
         "| child# : $child->[CHILD_NUMBER]\n",
         "| parent : $child->[CHILD_PARENT]\n",
         "| status : $child->[CHILD_OK]\n",
         "`------------------------------\n",
       );
}

exit 0;
