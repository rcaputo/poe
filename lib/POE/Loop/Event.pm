# $Id$

# Event.pm substrate for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Event;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other substrate module has been loaded.
BEGIN {
  die( "POE can't use Event and " . &POE_SUBSTRATE_NAME . "\n" )
    if defined &POE_SUBSTRATE;
};

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_EVENT      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_EVENT }

my ($kr_sessions, $kr_events);

#------------------------------------------------------------------------------
# Substrate construction and destruction.

sub _substrate_initialize {
  my $kernel = shift;
  $kr_sessions = $kernel->_get_kr_sessions_ref();
  $kr_events   = $kernel->_get_kr_events_ref();
}

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _substrate_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel->[KR_ACTIVE_SESSION],
      $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _substrate_signal_handler_child {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub substrate_watch_signal {
  my $signal = shift;

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

    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    Event->signal( signal => $signal,
                   cb     => \&_substrate_signal_handler_pipe
                 );
    return;
  }

  # Event doesn't like watching nonmaskable signals.
  return if $signal eq 'KILL' or $signal eq 'STOP';

  # Everything else.
  Event->signal( signal => $signal,
                 cb     => \&_substrate_signal_handler_generic
               );
}

sub substrate_resume_watching_child_signals {
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
    ) if keys(%$kr_sessions) > 1;
}

#------------------------------------------------------------------------------
# Watchers and callbacks.

### Time.

sub substrate_resume_time_watcher {
  my $next_time = shift;
  $poe_kernel->[KR_WATCHER_TIMER]->at($next_time);
  $poe_kernel->[KR_WATCHER_TIMER]->start();
}

sub substrate_reset_time_watcher {
  my $next_time = shift;
  substrate_pause_time_watcher();
  substrate_resume_time_watcher($next_time);
}

sub substrate_pause_time_watcher {
  $poe_kernel->[KR_WATCHER_TIMER]->stop();
}

### Filehandles.

sub substrate_watch_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  $kr_fno_vec->[FVC_WATCHER] =
    Event->io
      ( fd => $fileno,
        poll => ( ( $vector == VEC_RD )
                  ? 'r'
                  : ( ( $vector == VEC_WR )
                      ? 'w'
                      : 'e'
                    )
                ),
        cb => \&_substrate_select_callback,
      );
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

sub substrate_ignore_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  $kr_fno_vec->[FVC_WATCHER]->cancel();
  $kr_fno_vec->[FVC_WATCHER] = undef;
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}


sub substrate_pause_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  $kr_fno_vec->[FVC_WATCHER]->stop();
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

sub substrate_resume_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  $kr_fno_vec->[FVC_WATCHER]->start();
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

# Timer callback to dispatch events.
sub _substrate_event_callback {
  my $self = $poe_kernel;

  dispatch_due_events();

  # Register the next timed callback if there are events left.

  if (@$kr_events) {
    $self->[KR_WATCHER_TIMER]->at( $kr_events->[0]->[ST_TIME] );
    $self->[KR_WATCHER_TIMER]->start();

    # POE::Kernel's signal polling loop always keeps oe event in the
    # queue.  We test for an idle kernel if the queue holds only one
    # event.  A more generic method would be to keep counts of user
    # vs. kernel events, and GC the kernel when the user events drop
    # to 0.

    if (@$kr_events == 1) {
      test_for_idle_poe_kernel();
    }
  }

  # Make sure the kernel can still run.
  else {
    test_for_idle_poe_kernel();
  }
}

# Event filehandle callback to dispatch selects.
sub _substrate_select_callback {
  my $self = $poe_kernel;

  my $event = shift;
  my $watcher = $event->w;
  my $fileno = $watcher->fd;
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

  enqueue_ready_selects($fileno, $vector);
  test_for_idle_poe_kernel();
}

#------------------------------------------------------------------------------
# The event loop itself.

# ???
sub substrate_do_timeslice {
  die "doing timeslices currently not supported in the Event substrate";
}

# Initialize static watchers.
sub substrate_init_main_loop {
  $poe_kernel->[KR_WATCHER_TIMER] =
    Event->timer
      ( cb     => \&_substrate_event_callback,
        after  => 0,
        parked => 1,
      );
}

sub substrate_main_loop {
  Event::loop();
}

sub substrate_stop_main_loop {
  $poe_kernel->[KR_WATCHER_TIMER]->stop();
  Event::unloop_all(0);
}

sub signal_ui_destroy {
  # does nothing
}

1;
