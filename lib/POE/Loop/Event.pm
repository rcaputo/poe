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
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _substrate_signal_handler_pipe {
  $poe_kernel->_enqueue_state
    ( $poe_kernel->[KR_ACTIVE_SESSION],
      $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _substrate_signal_handler_child {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance macros.

macro watch_signal {
  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {
    Event->signal( signal => $signal,
                   cb     => \&_substrate_signal_handler_child
                 );
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

macro resume_watching_child_signals {
  # nothing to do
}

#------------------------------------------------------------------------------
# Watchers and callbacks.

macro substrate_resume_idle_watcher {
  $self->[KR_WATCHER_IDLE]->again();
}

macro substrate_resume_alarm_watcher {
  $self->[KR_WATCHER_TIMER]->at($self->[KR_ALARMS][0]->[ST_TIME]);
  $self->[KR_WATCHER_TIMER]->start();
}

macro substrate_pause_alarm_watcher {
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
  $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR]->stop();
}

macro substrate_resume_filehandle_write_watcher {
  $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR]->start();
}

macro substrate_pause_filehandle_read_watcher {
  $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD]->stop();
}

macro substrate_resume_filehandle_read_watcher {
  $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD]->start();
}

macro substrate_define_callbacks {
  # Event idle callback to dispatch FIFO states.
  sub _substrate_fifo_callback {
    my $self = $poe_kernel;

    {% dispatch_one_from_fifo %}

    # Stop the idle watcher if there are no more state transitions in
    # the Kernel's FIFO.

    unless (@{$self->[KR_STATES]}) {
      $self->[KR_WATCHER_IDLE]->stop();

      # Make sure the kernel can still run.
      {% test_for_idle_poe_kernel %}
    }
  }

  # Timer callback to dispatch alarm states.
  sub _substrate_alarm_callback {
    my $self = $poe_kernel;

    {% dispatch_due_alarms %}

    # Register the next timed callback if there are alarms left.

    if (@{$self->[KR_ALARMS]}) {
      $self->[KR_WATCHER_TIMER]->at( $self->[KR_ALARMS]->[0]->[ST_TIME] );
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

# Initialize static watchers.
macro substrate_init_main_loop {
  $self->[KR_WATCHER_TIMER] =
    Event->timer
      ( cb     => \&_substrate_alarm_callback,
        after  => 0,
        parked => 1,
      );

  $self->[KR_WATCHER_IDLE] =
    Event->idle
      ( cb     => \&_substrate_fifo_callback,
        repeat => 1,
        min    => 0,
        max    => 0,
        parked => 1,
      );
}

macro substrate_start_main_loop {
  Event::loop();
}

macro substrate_stop_main_loop {
  $self->[KR_WATCHER_IDLE]->stop();
  $self->[KR_WATCHER_TIMER]->stop();
  Event::unloop_all(0);
}

1;
