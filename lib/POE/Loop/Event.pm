# $Id$

# Event.pm event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Loop::Event;

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

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  $_watcher_timer =
    Event->timer
      ( cb     => \&_loop_event_callback,
        after  => 0,
        parked => 1,
      );
}

sub loop_finalize {
  my $self = shift;

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
    ( time(),
      $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0]->w->signal ],
      __FILE__, __LINE__
    );
}

sub _loop_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( time(),
      $poe_kernel->get_active_session(), $poe_kernel,
      EN_SIGNAL, ET_SIGNAL, [ $_[0]->w->signal ],
      __FILE__, __LINE__
    );
}

sub _loop_signal_handler_child {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( time(),
      $poe_kernel, $poe_kernel, EN_SCPOLL, ET_SCPOLL, [ ],
      __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my ($self, $signal) = @_;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $self->_enqueue_event
      ( time() + 1, $self, $self, EN_SCPOLL, ET_SCPOLL, [ ],
        __FILE__, __LINE__
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

sub loop_ignore_signal {
  my ($self, $signal) = @_;
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
  my ($self, $next_time) = @_;
  $_watcher_timer->at($next_time);
  $_watcher_timer->start();
}

sub loop_reset_time_watcher {
  my ($self, $next_time) = @_;
  $self->loop_pause_time_watcher();
  $self->loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
  $_watcher_timer->stop();
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($self, $handle, $vector) = @_;
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
}

sub loop_ignore_filehandle {
  my ($self, $handle, $vector) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->cancel();
  $fileno_watcher[$fileno] = undef;
}

sub loop_pause_filehandle_watcher {
  my ($self, $handle, $vector) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->stop();
}

sub loop_resume_filehandle_watcher {
  my ($self, $handle, $vector) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->start();
}

# Timer callback to dispatch events.
sub _loop_event_callback {
  my $self = $poe_kernel;

  $self->_data_dispatch_due_events();

  # Register the next timed callback if there are events left.

  my $next_time = $self->get_next_event_time();
  if (defined $next_time) {
    $_watcher_timer->at($next_time);
    $_watcher_timer->start();

    # POE::Kernel's signal polling loop always keeps oe event in the
    # queue.  We test for an idle kernel if the queue holds only one
    # event.  A more generic method would be to keep counts of user
    # vs. kernel events, and GC the kernel when the user events drop
    # to 0.

    if ($self->get_session_count() == 1) {
      $self->_data_test_for_idle_poe_kernel();
    }
  }

  # Make sure the kernel can still run.
  else {
    $self->_data_test_for_idle_poe_kernel();
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

  $self->_data_handle_enqueue_ready($vector, $fileno);
  $self->_data_test_for_idle_poe_kernel();
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
