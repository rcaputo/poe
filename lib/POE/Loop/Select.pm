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

# Linux has a bug on "polled" select() calls.  If select() is called
# with a zero-second timeout, and a signal manages to interrupt it
# anyway (it's happened), the select() function is restarted and will
# block indefinitely.  Set the minimum select() timeout to 1us on
# Linux systems.
BEGIN {
  my $timeout = ($^O eq 'linux') ? 0.001 : 0;
  eval "sub MINIMUM_SELECT_TIMEOUT () { $timeout }";
};

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_substrate_signal_handler_generic;
}

sub _substrate_signal_handler_pipe {
  $poe_kernel->_enqueue_event
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
  $poe_kernel->_enqueue_event
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

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $poe_kernel->_enqueue_event
      ( $poe_kernel, $poe_kernel,
        EN_SCPOLL, ET_SCPOLL,
        [ ],
        time() + 1, __FILE__, __LINE__
      ) if $signal eq 'CHLD' or not exists $SIG{CHLD};

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
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%kr_sessions) > 1;
}

#------------------------------------------------------------------------------
# Event watchers and callbacks.

### Time.

macro substrate_resume_time_watcher {
  # does nothing
}

macro substrate_reset_time_watcher {
  # does nothing
}

macro substrate_pause_time_watcher {
  # does nothing
}

### Filehandles.

macro substrate_watch_filehandle (<fileno>,<vector>) {
  if (TRACE_SELECT) {
    warn( "??? watching fileno (", <fileno>, ") vector (", <vector>,
          ") count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  vec($kr_vectors[<vector>], <fileno>, 1) = 1;
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

macro substrate_ignore_filehandle (<fileno>,<vector>) {
  if (TRACE_SELECT) {
    warn( "??? ignoring fileno (", <fileno>, ") vector (", <vector>,
          ") count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  vec($kr_vectors[<vector>], <fileno>, 1) = 0;
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}

macro substrate_pause_filehandle_watcher (<fileno>,<vector>) {
  if (TRACE_SELECT) {
    warn( "??? pausing fileno (", <fileno>, ") vector (", <vector>,
          ") count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  vec($kr_vectors[<vector>], <fileno>, 1) = 0;
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

macro substrate_resume_filehandle_watcher (<fileno>,<vector>) {
  if (TRACE_SELECT) {
    warn( "??? resuming fileno (", <fileno>, ") vector (", <vector>,
          ") count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  vec($kr_vectors[<vector>], <fileno>, 1) = 1;
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
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

macro substrate_do_timeslice {
  # Check for a hung kernel.
  {% test_for_idle_poe_kernel %}

  # Set the select timeout based on current queue conditions.  If
  # there are FIFO events, then the timeout is zero to poll select and
  # move on.  Otherwise set the select timeout until the next pending
  # event, if there are any.  If nothing is waiting, set the timeout
  # for some constant number of seconds.

  my $now = time();
  my $timeout;

  if (@kr_events) {
    $timeout = $kr_events[0]->[ST_TIME] - $now;
    $timeout = MINIMUM_SELECT_TIMEOUT if $timeout < MINIMUM_SELECT_TIMEOUT;
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
    warn( '*** Event times: ' .
          join( ', ',
                map { sprintf('%d=%.2f',
                              $_->[ST_SEQ], $_->[ST_TIME] - $now
                             )
                    } @kr_events
              ) .
          "\n"
        );
  }

  # Ensure that the event queue remains in time order.
  if (ASSERT_EVENTS and @kr_events) {
    my $previous_time = $kr_events[0]->[ST_TIME];
    foreach (@kr_events) {
      die "event $_->[ST_SEQ] is out of order"
        if $_->[ST_TIME] < $previous_time;
      $previous_time = $_->[ST_TIME];
    }
  }

  my $fileno = 0;
  @filenos = ();
  foreach (@kr_filenos) {
    push(@filenos, $fileno) if defined $_;
    $fileno++;
  }

  if (TRACE_SELECT) {
    warn ",----- SELECT BITS IN -----\n";
    warn "| READ    : ", unpack('b*', $kr_vectors[VEC_RD]), "\n";
    warn "| WRITE   : ", unpack('b*', $kr_vectors[VEC_WR]), "\n";
    warn "| EXPEDITE: ", unpack('b*', $kr_vectors[VEC_EX]), "\n";
    warn "`--------------------------\n";
  }

  # Avoid looking at filehandles if we don't need to.  -><- The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if ($timeout or @filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = select( my $rout = $kr_vectors[VEC_RD],
                         my $wout = $kr_vectors[VEC_WR],
                         my $eout = $kr_vectors[VEC_EX],
                         $timeout,
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
      # appropriate handlers.

      if ($hits > 0) {

        # This is where they're gathered.  It's a variant on a neat
        # hack Silmaril came up with.

        my (@rd_selects, @wr_selects, @ex_selects);
        foreach (@filenos) {
          push(@rd_selects, $_) if vec($rout, $_, 1);
          push(@wr_selects, $_) if vec($wout, $_, 1);
          push(@ex_selects, $_) if vec($eout, $_, 1);
        }

        if (TRACE_SELECT) {
          if (@rd_selects) {
            warn( "found pending rd selects: ",
                  join( ', ', sort { $a <=> $b } @rd_selects ),
                  "\n"
                );
          }
          if (@wr_selects) {
            warn( "found pending wr selects: ",
                  join( ', ', sort { $a <=> $b } @wr_selects ),
                  "\n"
                );
          }
          if (@ex_selects) {
            warn( "found pending ex selects: ",
                  join( ', ', sort { $a <=> $b } @ex_selects ),
                  "\n"
                );
          }
        }

        if (ASSERT_SELECT) {
          unless (@rd_selects or @wr_selects or @ex_selects) {
            die "found no selects, with $hits hits from select???\a\n";
          }
        }

        # Enqueue the gathered selects, and flag them as temporarily
        # paused.  They'll resume after dispatch.

        foreach my $fileno (@rd_selects) {
          {% enqueue_ready_selects $fileno, VEC_RD %}
        }

        foreach my $fileno (@wr_selects) {
          {% enqueue_ready_selects $fileno, VEC_WR %}
        }

        foreach my $fileno (@ex_selects) {
          {% enqueue_ready_selects $fileno, VEC_EX %}
        }
      }
    }

    # No filehandles to select on.  Try to sleep instead.  Use sleep()
    # itself on MSWin32.  Use a dummy four-argument select()
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

  # Dispatch whatever events are due.

  $now = time();
  while ( @kr_events and ($kr_events[0]->[ST_TIME] <= $now) ) {
    my $event;

    if (TRACE_QUEUE) {
      $event = $kr_events[0];
      warn( sprintf('now(%.2f) ', $now - $^T) .
            sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
            "seq($event->[ST_SEQ])  " .
            "name($event->[ST_NAME])\n"
          );
    }

    # Pull an event off the queue, and dispatch it.
    $event = shift @kr_events;
    delete $kr_event_ids{$event->[ST_SEQ]};
    {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}
    {% ses_refcount_dec2 $event->[ST_SOURCE], SS_POST_COUNT %}
    $self->_dispatch_event(@$event);
  }
}

macro substrate_main_loop {
  # Run for as long as there are sessions to service.
  while (keys %kr_sessions) {
    {% substrate_do_timeslice %}
  }
}

macro substrate_stop_main_loop {
  # does nothing
}

sub signal_ui_destroy {
  # does nothing
}

1;
