# $Id$

# Event.pm event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Event;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Declare which event loop bridge is being used, but first ensure that
# no other bridge has been loaded.

BEGIN {
  die( "POE can't use Event and " . &POE_LOOP . "\n" )
    if defined &POE_LOOP;
};

sub POE_LOOP () { LOOP_EVENT }

my $_watcher_timer;
my @fileno_watcher;
my %signal_watcher;

my ($kr_sessions, $kr_events);

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $kernel = shift;
  $kr_sessions = $kernel->_get_kr_sessions_ref();
  $kr_events   = $kernel->_get_kr_events_ref();

  $_watcher_timer =
    Event->timer
      ( cb     => \&_loop_event_callback,
        after  => 0,
        parked => 1,
      );
}

sub loop_finalize {
  for (0..$#fileno_watcher) {
    warn "Watcher for fileno $_ is allocated during loop finalize"
      if defined $fileno_watcher[$_];
  }
}

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _loop_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel->[KR_ACTIVE_SESSION],
      $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0]->w->signal ],
      time(), __FILE__, __LINE__
    );
}

sub _loop_signal_handler_child {
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

sub loop_watch_signal {
  my $signal = shift;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

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
    $signal_watcher{$signal} =
      Event->signal( signal => $signal,
                     cb     => \&_loop_signal_handler_pipe
                   );
    return;
  }

  # Event doesn't like watching nonmaskable signals.
  return if $signal eq 'KILL' or $signal eq 'STOP';

  # Everything else.
  $signal_watcher{$signal} =
    Event->signal( signal => $signal,
                   cb     => \&_loop_signal_handler_generic
                 );
}

sub loop_resume_watching_child_signals {
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

sub loop_ignore_signal {
  my $signal = shift;
  if (defined $signal_watcher{$signal}) {
    $signal_watcher{$signal}->stop();
    delete $signal_watcher{$signal};
  }
}

sub loop_attach_uidestroy {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  my $next_time = shift;
  $_watcher_timer->at($next_time);
  $_watcher_timer->start();
}

sub loop_reset_time_watcher {
  my $next_time = shift;
  loop_pause_time_watcher();
  loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
  $_watcher_timer->stop();
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  $fileno_watcher[$fileno] =
    Event->io
      ( fd => $fileno,
        poll => ( ( $vector == VEC_RD )
                  ? 'r'
                  : ( ( $vector == VEC_WR )
                      ? 'w'
                      : 'e'
                    )
                ),
        cb => \&_loop_select_callback,
      );
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

sub loop_ignore_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->cancel();
  $fileno_watcher[$fileno] = undef;
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}


sub loop_pause_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->stop();
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

sub loop_resume_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->start();
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

# Timer callback to dispatch events.
sub _loop_event_callback {
  my $self = $poe_kernel;

  dispatch_due_events();

  # Register the next timed callback if there are events left.

  if (@$kr_events) {
    $_watcher_timer->at( $kr_events->[0]->[ST_TIME] );
    $_watcher_timer->start();

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
sub _loop_select_callback {
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

sub loop_do_timeslice {
  die "doing timeslices currently not supported in the Event loop";
}

sub loop_run {
  Event::loop();
}

sub loop_halt {
  $_watcher_timer->stop();
  Event::unloop_all(0);
}

1;
