# $Id$

# Select loop substrate for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Select;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other substrate module has been loaded.
BEGIN {
  die( "POE can't use its own loop and " . &POE_SUBSTRATE_NAME . "\n" )
    if defined &POE_SUBSTRATE;
};

use POE::Preprocessor;

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_SELECT      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_SELECT }

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_substrate_signal_handler_generic;
}

sub _substrate_signal_handler_pipe {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_substrate_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _substrate_signal_handler_child {
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance macros.

macro substrate_watch_signal {
  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # For SIGCHLD triggered polling loop.
    # $SIG{$signal} = \&_substrate_signal_handler_child;

    # Begin constant polling loop.
    $SIG{$signal} = 'DEFAULT';
    $poe_kernel->_enqueue_alarm
      ( $poe_kernel, $poe_kernel,
        EN_SCPOLL, ET_SCPOLL,
        [ ],
        time() + 1, __FILE__, __LINE__
      );

    next;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_substrate_signal_handler_pipe;
    next;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  next if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_substrate_signal_handler_generic;
}

macro substrate_resume_watching_child_signals {
  # For SIGCHLD triggered polling loop.
  # $SIG{CHLD} = \&_substrate_signal_handler_child if exists $SIG{CHLD};
  # $SIG{CLD}  = \&_substrate_signal_handler_child if exists $SIG{CLD};

  # For constant polling loop.
  $SIG{CHLD} = 'DEFAULT' if exists $SIG{CHLD};
  $SIG{CLD}  = 'DEFAULT' if exists $SIG{CLD};
  $poe_kernel->_enqueue_alarm
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%kr_sessions) > 1;
}

#------------------------------------------------------------------------------
# Event watchers and callbacks.

macro substrate_resume_idle_watcher {
  # does nothing
}

macro substrate_resume_alarm_watcher {
  # does nothing
}

macro substrate_reset_alarm_watcher {
  # does nothing
}

macro substrate_pause_alarm_watcher {
  # does nothing
}

macro substrate_watch_filehandle {
  vec($kr_vectors[$select_index], fileno($handle), 1) = 1;
}

macro substrate_ignore_filehandle {
  vec($kr_vectors[$select_index], fileno($handle), 1) = 0;

  # Shrink the bit vector by chopping zero octets from the end.
  # Octets because that's the minimum size of a bit vector chunk that
  # Perl manages.  Always keep at least one octet around, even if it's
  # 0.  -><- Why?

  $kr_vectors[$select_index] =~ s/(.)\000+$/$1/;
}

macro substrate_pause_filehandle_write_watcher {
  # Turn off the select vector's write bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.
  vec($kr_vectors[VEC_WR], fileno($handle), 1) = 0;
}

macro substrate_resume_filehandle_write_watcher {
  # Turn the select vector's write bit back on.
  vec($kr_vectors[VEC_WR], fileno($handle), 1) = 1;
}

macro substrate_pause_filehandle_read_watcher {
  # Turn off the select vector's read bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.
  vec($kr_vectors[VEC_RD], fileno($handle), 1) = 0;
}

macro substrate_resume_filehandle_read_watcher {
  # Turn the select vector's read bit back on.
  vec($kr_vectors[VEC_RD], fileno($handle), 1) = 1;
}

macro substrate_define_callbacks {
  # does nothing
}

#------------------------------------------------------------------------------
# Main loop management.

macro substrate_init_main_loop {
  # Initialize the vectors as vectors.
  vec($kr_vectors[VEC_RD], 0, 1) = 0;
  vec($kr_vectors[VEC_WR], 0, 1) = 0;
  vec($kr_vectors[VEC_EX], 0, 1) = 0;
}

macro substrate_main_loop {
  # Run for as long as there are sessions to service.

  while (keys %kr_sessions) {

    # Check for a hung kernel.
    {% test_for_idle_poe_kernel %}

    # Set the select timeout based on current queue conditions.  If
    # there are FIFO events, then the timeout is zero to poll select
    # and move on.  Otherwise set the select timeout until the next
    # pending alarm, if any are in the alarm queue.  If no FIFO events
    # or alarms are pending, then time out after some constant number
    # of seconds.

    my $now = time();
    my $timeout;

    if (@kr_states) {
      $timeout = 0;
    }
    elsif (@kr_alarms) {
      $timeout = $kr_alarms[0]->[ST_TIME] - $now;
      $timeout = 0 if $timeout < 0;
    }
    else {
      $timeout = 3600;
    }

    if (TRACE_QUEUE) {
      warn( '*** Kernel::run() iterating.  ' .
            sprintf("now(%.2f) timeout(%.2f) then(%.2f)\n",
                    $now-$^T, $timeout, ($now-$^T)+$timeout
                   )
          );
      warn( '*** Alarm times: ' .
            join( ', ',
                  map { sprintf('%d=%.2f',
                                $_->[ST_SEQ], $_->[ST_TIME] - $now
                               )
                      } @kr_alarms
                ) .
            "\n"
          );
    }

    # Ensure that the alarm queue remains in time order.
    if (ASSERT_ALARMS and @kr_alarms) {
      my $previous_time = $kr_alarms[0]->[ST_TIME];
      foreach (@kr_alarms) {
        die "alarm $_->[ST_SEQ] is out of order"
          if $_->[ST_TIME] < $previous_time;
        $previous_time = $_->[ST_TIME];
      }
    }

    if (TRACE_SELECT) {
      warn ",----- SELECT BITS IN -----\n";
      warn "| READ    : ", unpack('b*', $kr_vectors[VEC_RD]), "\n";
      warn "| WRITE   : ", unpack('b*', $kr_vectors[VEC_WR]), "\n";
      warn "| EXPEDITE: ", unpack('b*', $kr_vectors[VEC_EX]), "\n";
      warn "`--------------------------\n";
    }

    # Avoid looking at filehandles if we don't need to.  -><- The
    # added code to make this sleep is non-optimal.  There is a way to
    # do this in fewer tests.

    if ($timeout || keys(%kr_handles)) {

      # There are filehandles to poll, so do so.

      if (keys(%kr_handles)) {
        # Check filehandles, or wait for a period of time to elapse.
        my $hits = select( my $rout = $kr_vectors[VEC_RD],
                           my $wout = $kr_vectors[VEC_WR],
                           my $eout = $kr_vectors[VEC_EX],
                           ($timeout < 0) ? 0 : $timeout
                         );

        if (ASSERT_SELECT) {
          if ($hits < 0) {
            confess "select error: $!"
              unless ( ($! == EINPROGRESS) or
                       ($! == EWOULDBLOCK) or
                       ($! == EINTR)
                     );
          }
        }

        if (TRACE_SELECT) {
          if ($hits > 0) {
            warn "select hits = $hits\n";
          }
          elsif ($hits == 0) {
            warn "select timed out...\n";
          }
          warn ",----- SELECT BITS OUT -----\n";
          warn "| READ    : ", unpack('b*', $rout), "\n";
          warn "| WRITE   : ", unpack('b*', $wout), "\n";
          warn "| EXPEDITE: ", unpack('b*', $eout), "\n";
          warn "`---------------------------\n";
        }

        # If select has seen filehandle activity, then gather up the
        # active filehandles and synchronously dispatch events to the
        # appropriate states.

        if ($hits > 0) {

          # This is where they're gathered.  It's a variant on a neat
          # hack Silmaril came up with.

          # -><- This does extra work.  Some of $%kr_handles don't have
          # all their bits set (for example; VEX_EX is rarely used).  It
          # might be more efficient to split this into three greps, for
          # just the vectors that need to be checked.

          # -><- It has been noted that map is slower than foreach when
          # the size of a list is grown.  The list is exploded on the
          # stack and manipulated with stack ops, which are slower than
          # just pushing on a list.  Evil probably ensues here.

          my @selects =
            map { ( ( vec($rout, fileno($_->[HND_HANDLE]), 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_RD]})
                      : ( )
                    ),
                    ( vec($wout, fileno($_->[HND_HANDLE]), 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_WR]})
                      : ( )
                    ),
                    ( vec($eout, fileno($_->[HND_HANDLE]), 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_EX]})
                      : ( )
                    )
                  )
                } values %kr_handles;

          if (TRACE_SELECT) {
            if (@selects) {
              warn( "found pending selects: ",
                    join( ', ',
                          sort { $a <=> $b }
                          map { fileno($_->[HND_HANDLE]) }
                          @selects
                        ),
                    "\n"
                  );
            }
          }

          if (ASSERT_SELECT) {
            unless (@selects) {
              die "found no selects, with $hits hits from select???\a\n";
            }
          }

          # Dispatch the gathered selects.  They're dispatched right
          # away because files will continue to unblock select until
          # they're taken care of.  The idea is for select handlers to
          # do whatever is needed to shut up select, and then they post
          # something indicating what input was got.  Nobody seems to
          # use them this way, though, not even the author.

          foreach my $select (@selects) {
            $self->_dispatch_state
              ( $select->[HSS_SESSION], $select->[HSS_SESSION],
                $select->[HSS_STATE], ET_SELECT,
                [ $select->[HSS_HANDLE] ],
                time(), __FILE__, __LINE__, undef
              );
          }
        }
      }

      # No filehandles to select on.  Try to sleep instead.  Use
      # sleep() itself on MSWin32.  Use a dummy four-argument select()
      # everywhere else.

      else {
        if ($^O eq 'MSWin32') {
          sleep($timeout);
        }
        else {
          select(undef, undef, undef, $timeout);
        }
      }
    }

    # Dispatch whatever alarms are due.

    $now = time();
    while ( @kr_alarms and ($kr_alarms[0]->[ST_TIME] <= $now) ) {
      my $event;

      if (TRACE_QUEUE) {
        $event = $kr_alarms[0];
        warn( sprintf('now(%.2f) ', $now - $^T) .
              sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
              "seq($event->[ST_SEQ])  " .
              "name($event->[ST_NAME])\n"
            );
      }

      # Pull an alarm off the queue, and dispatch it.
      $event = shift @kr_alarms;
      delete $kr_alarm_ids{$event->[ST_SEQ]};
      {% ses_refcount_dec2 $event->[ST_SESSION], SS_ALCOUNT %}
      $self->_dispatch_state(@$event);
    }

    # Dispatch one or more FIFOs, if they are available.  There is a
    # lot of latency between executions of this code block, so we'll
    # dispatch more than one event if we can.

    my $stop_time = time() + FIFO_DISPATCH_TIME;
    while (@kr_states) {

      if (TRACE_QUEUE) {
        my $event = $kr_states[0];
        warn( sprintf('now(%.2f) ', $now - $^T) .
              sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
              "seq($event->[ST_SEQ])  " .
              "name($event->[ST_NAME])\n"
            );
      }

      # Pull an event off the queue, and dispatch it.
      my $event = shift @kr_states;
      {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}
      $self->_dispatch_state(@$event);

      # If we have high-resolution time, dispatch more FIFO events
      # until the stop time is reached.
      last unless POE_USES_TIME_HIRES and time() < $stop_time;
    }
  }
}

macro substrate_stop_main_loop {
  # does nothing
}

sub signal_ui_destroy {
  # does nothing
}

1;
