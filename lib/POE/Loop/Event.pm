# $Id$

# Event.pm substrate for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Event;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other substrate module has been loaded.
BEGIN {
  die( "POE can't use Event and " . &POE_SUBSTRATE_NAME . "\n" )
    if defined &POE_SUBSTRATE;
};

use POE::Preprocessor;

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_EVENT      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_EVENT }

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _substrate_signal_handler_pipe {
  $poe_kernel->_enqueue_event
    ( $poe_kernel->[KR_ACTIVE_SESSION],
      $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _substrate_signal_handler_child {
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
    # Event->signal( signal => $signal,
    #                cb     => \&_substrate_signal_handler_child
    #              );

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
    Event->signal( signal => $signal,
                   cb     => \&_substrate_signal_handler_pipe
                 );
    next;
  }

  # Event doesn't like watching nonmaskable signals.
  next if $signal eq 'KILL' or $signal eq 'STOP';

  # Everything else.
  Event->signal( signal => $signal,
                 cb     => \&_substrate_signal_handler_generic
               );
}

macro substrate_resume_watching_child_signals {
  # For SIGCHLD triggered polling loop.
  # nothing to do

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
# Watchers and callbacks.

macro substrate_resume_time_watcher {
  $self->[KR_WATCHER_TIMER]->at($kr_events[0]->[ST_TIME]);
  $self->[KR_WATCHER_TIMER]->start();
}

macro substrate_reset_time_watcher {
  {% substrate_pause_time_watcher %}
  {% substrate_resume_time_watcher %}
}

macro substrate_pause_time_watcher {
  $self->[KR_WATCHER_TIMER]->stop();
}

macro substrate_watch_filehandle {
  $kr_handle->[HND_WATCHERS]->[$select_index] =
    Event->io
      ( fd => $handle,
        poll => ( ( $select_index == VEC_RD )
                  ? 'r'
                  : ( ( $select_index == VEC_WR )
                      ? 'w'
                      : 'e'
                    )
                ),
        cb => \&_substrate_select_callback,
      );
}

macro substrate_ignore_filehandle {
  $kr_handle->[HND_WATCHERS]->[$select_index]->cancel();
  $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
}

macro substrate_pause_filehandle_write_watcher {
  $kr_handles{$handle}->[HND_WATCHERS]->[VEC_WR]->stop();
}

macro substrate_resume_filehandle_write_watcher {
  $kr_handles{$handle}->[HND_WATCHERS]->[VEC_WR]->start();
}

macro substrate_pause_filehandle_read_watcher {
  $kr_handles{$handle}->[HND_WATCHERS]->[VEC_RD]->stop();
}

macro substrate_resume_filehandle_read_watcher {
  $kr_handles{$handle}->[HND_WATCHERS]->[VEC_RD]->start();
}

macro substrate_define_callbacks {

  # Timer callback to dispatch events.
  sub _substrate_event_callback {
    my $self = $poe_kernel;

    {% dispatch_due_events %}

    # Register the next timed callback if there are events left.

    if (@kr_events) {
      $self->[KR_WATCHER_TIMER]->at( $kr_events[0]->[ST_TIME] );
      $self->[KR_WATCHER_TIMER]->start();
    }

    # Make sure the kernel can still run.
    else {
      {% test_for_idle_poe_kernel %}
    }
  }

  # Event filehandle callback to dispatch selects.
  sub _substrate_select_callback {
    my $self = $poe_kernel;

    my $event = shift;
    my $watcher = $event->w;
    my $handle = $watcher->fd;
    my $vector = ( ( $event->got eq 'r' )
                   ? VEC_RD
                   : ( ( $event->got eq 'w' )
                       ? VEC_WR
                       : ( ( $event->got eq 'e' )
                           ? VEC_EX
                           : return
                         )
                     )
                 );

    {% dispatch_ready_selects %}
    {% test_for_idle_poe_kernel %}
  }
}

#------------------------------------------------------------------------------
# The event loop itself.

# ???
macro substrate_do_timeslice {
  die "doing timeslices currently not supported in the Event substrate";
}

# Initialize static watchers.
macro substrate_init_main_loop {
  $self->[KR_WATCHER_TIMER] =
    Event->timer
      ( cb     => \&_substrate_event_callback,
        after  => 0,
        parked => 1,
      );
}

macro substrate_main_loop {
  Event::loop();
}

macro substrate_stop_main_loop {
  $self->[KR_WATCHER_TIMER]->stop();
  Event::unloop_all(0);
}

sub signal_ui_destroy {
  # does nothing
}

1;
