# $Id$

# Event.pm personality module for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Event;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other personality module has been loaded.
BEGIN {
  die( "POE can't use Event and " . &POE_PERSONALITY_NAME . "\n" )
    if defined &POE_PERSONALITY;
};

use POE::Preprocessor;

# Declare the personality we're using.
sub POE_PERSONALITY      () { PERSONALITY_EVENT      }
sub POE_PERSONALITY_NAME () { PERSONALITY_NAME_EVENT }

#------------------------------------------------------------------------------
# Define signal handlers and the functions that define them.

sub _signal_handler_generic {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _signal_handler_pipe {
  $poe_kernel->_enqueue_state
    ( $poe_kernel->[KR_ACTIVE_SESSION],
      $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _signal_handler_child {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time(), __FILE__, __LINE__
    );
}

sub _watch_signal {
  my $signal = shift;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {
    Event->signal( signal => $signal,
                   cb     => \&_signal_handler_child
                 );
    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    Event->signal( signal => $signal,
                   cb     => \&_signal_handler_pipe
                 );
    return;
  }

  # Event doesn't like watching nonmaskable signals.
  return if $signal eq 'KILL' or $signal eq 'STOP';

  # Everything else.
  Event->signal( signal => $signal,
                 cb     => \&_signal_handler_generic
               );
}

# Nothing to do.
sub _resume_watching_child_signals () { undef }

#------------------------------------------------------------------------------
# Watchers and callbacks.

sub _resume_idle_watcher {
  $poe_kernel->[KR_WATCHER_IDLE]->again();
}

sub _resume_alarm_watcher {
  $poe_kernel->[KR_WATCHER_TIMER]->at($poe_kernel->[KR_ALARMS][0]->[ST_TIME]);
  $poe_kernel->[KR_WATCHER_TIMER]->start();
}

sub _pause_alarm_watcher {
  $poe_kernel->[KR_WATCHER_TIMER]->stop();
}

sub _watch_filehandle {
  my ($kr_handle, $handle, $select_index) = @_;
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
        cb => \&_select_callback,
      );
}

sub _ignore_filehandle {
  my ($kr_handle, $handle, $select_index) = @_;
  $kr_handle->[HND_WATCHERS]->[$select_index]->cancel();
  $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
}

sub _pause_filehandle_write_watcher {
  my $handle = shift;
  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR]->stop();
}

sub _resume_filehandle_write_watcher {
  my $handle = shift;
  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR]->start();
}

sub _pause_filehandle_read_watcher {
  my $handle = shift;
  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD]->stop();
}

sub _resume_filehandle_read_watcher {
  my $handle = shift;
  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD]->start();
}

# Event idle callback to dispatch FIFO states.

sub _fifo_callback {
  my $self = $poe_kernel;

  _dispatch_one_from_fifo();

  # Stop the idle watcher if there are no more state transitions in
  # the Kernel's FIFO.

  unless (@{$self->[KR_STATES]}) {
    $self->[KR_WATCHER_IDLE]->stop();

    # Make sure the kernel can still run.
    _test_for_idle_poe_kernel();
  }
}

# Timer callback to dispatch alarm states.

sub _alarm_callback {
  my $self = $poe_kernel;

  _dispatch_due_alarms();

  # Register the next timed callback if there are alarms left.

  if (@{$self->[KR_ALARMS]}) {
    $self->[KR_WATCHER_TIMER]->at( $self->[KR_ALARMS]->[0]->[ST_TIME] );
    $self->[KR_WATCHER_TIMER]->start();
  }

  # Make sure the kernel can still run.
  else {
    _test_for_idle_poe_kernel();
  }
}

# Event filehandle callback to dispatch selects.

sub _select_callback {
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

  _dispatch_ready_selects( $handle, $vector );
  _test_for_idle_poe_kernel();
}


#------------------------------------------------------------------------------
# The event loop itself.

# Initialize static watchers.
sub _init_main_loop ($) {
  my $self = shift;

  $self->[KR_WATCHER_TIMER] =
    Event->timer
      ( cb     => \&_alarm_callback,
        after  => 0,
        parked => 1,
      );

  $self->[KR_WATCHER_IDLE] =
    Event->idle
      ( cb     => \&_fifo_callback,
        repeat => 1,
        min    => 0,
        max    => 0,
        parked => 1,
      );
}

sub _start_main_loop {
  Event::loop();
}

sub _stop_main_loop {
  $poe_kernel->[KR_WATCHER_IDLE]->stop();
  $poe_kernel->[KR_WATCHER_TIMER]->stop();
  Event::unloop_all(0);
}

1;
