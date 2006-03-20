# $Id$

# Event.pm event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Loop::Event;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

my $_watcher_timer;
my @fileno_watcher;
my %signal_watcher;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub _our_event_exception_handler {
  my ($event, $message) = @_;
  warn $message;
  exit 1;
}

sub loop_initialize {
  my $self = shift;

  $Event::DIED = \&_our_event_exception_handler;

  $_watcher_timer = Event->timer(
    cb     => \&_loop_event_callback,
    after  => 0,
    parked => 1,
  );
}

sub loop_finalize {
  foreach my $fd (0..$#fileno_watcher) {
    next unless defined $fileno_watcher[$fd];
    foreach my $mode (MODE_RD, MODE_WR, MODE_EX) {
      POE::Kernel::_warn(
        "Mode $mode watcher for fileno $fd is defined during loop finalize"
      ) if defined $fileno_watcher[$fd]->[$mode];
    }
  }
}

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing generic SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0]->w->signal ],
    __FILE__, __LINE__, undef, time(),
  );
}

sub _loop_signal_handler_pipe {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing PIPE-like SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel->get_active_session(), $poe_kernel,
    EN_SIGNAL, ET_SIGNAL, [ $_[0]->w->signal ],
    __FILE__, __LINE__, undef, time(),
  );
}

sub _loop_signal_handler_child {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing CHLD-like SIG$_[0] event";
  }

  $poe_kernel->_idle_queue_grow();
  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SCPOLL, ET_SCPOLL, [ ],
    __FILE__, __LINE__, undef, time(),
  );
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my ($self, $signal) = @_;

  # Child process has stopped.  We use Event's safe SIGCHLD handler.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {
    $SIG{$signal} = "DEFAULT";
    $signal_watcher{CHLD} = Event->signal(
      signal => $signal,
      cb     => \&_loop_signal_handler_child
    );
    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = "DEFAULT";
    $signal_watcher{$signal} = Event->signal(
      signal => $signal,
      cb     => \&_loop_signal_handler_pipe
    );
    return;
  }

  # Event doesn't like watching nonmaskable signals.
  return if $signal eq 'KILL' or $signal eq 'STOP';

  # Everything else.
  $signal_watcher{$signal} = Event->signal(
    signal => $signal,
    cb     => \&_loop_signal_handler_generic
  );
}

sub loop_ignore_signal {
  my ($self, $signal) = @_;

  if (defined $signal_watcher{$signal}) {
    $signal_watcher{$signal}->stop();
    delete $signal_watcher{$signal};
  }

  # Certain kinds of signals should be ignored by default.
  if ($signal =~ /^(CH?LD|PIPE)$/) {
    $SIG{$signal} = "IGNORE";
    return;
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
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  # Overwriting a pre-existing watcher?
  if (defined $fileno_watcher[$fileno]->[$mode]) {
    $fileno_watcher[$fileno]->[$mode]->cancel();
    undef $fileno_watcher[$fileno]->[$mode];
  }

  $fileno_watcher[$fileno]->[$mode] = Event->io(
    fd => $fileno,
    poll => (
      ( $mode == MODE_RD )
      ? 'r'
      : (
        ( $mode == MODE_WR )
        ? 'w'
        : 'e'
      )
    ),
    cb => \&_loop_select_callback,
  );
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  # Don't bother removing a select if none was registered.
  if (defined $fileno_watcher[$fileno]->[$mode]) {
    $fileno_watcher[$fileno]->[$mode]->cancel();
    undef $fileno_watcher[$fileno]->[$mode];
  }
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->[$mode]->stop();
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);
  $fileno_watcher[$fileno]->[$mode]->start();
}

# Timer callback to dispatch events.

my $last_time = time();

sub _loop_event_callback {
  my $self = $poe_kernel;

  if (TRACE_STATISTICS) {
    # TODO - I'm pretty sure the startup time will count as an unfair
    # amount of idleness.
    #
    # TODO - Introducing many new time() syscalls.  Bleah.
    $self->_data_stat_add('idle_seconds', time() - $last_time);
  }

  $self->_data_ev_dispatch_due();
  $self->_test_if_kernel_is_idle();

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

    if ($self->_data_ses_count() == 1) {
      $self->_test_if_kernel_is_idle();
    }
  }

  # Transferring control back to Event; this is idle time.
  $last_time = time() if TRACE_STATISTICS;
}

# Event filehandle callback to dispatch selects.
sub _loop_select_callback {
  my $self = $poe_kernel;

  my $event = shift;
  my $watcher = $event->w;
  my $fileno = $watcher->fd;
  my $mode = (
    ( $event->got eq 'r' )
    ? MODE_RD
    : (
      ( $event->got eq 'w' )
      ? MODE_WR
      : (
        ( $event->got eq 'e' )
        ? MODE_EX
        : return
      )
    )
  );

  $self->_data_handle_enqueue_ready($mode, $fileno);
  $self->_test_if_kernel_is_idle();
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

__END__

=head1 NAME

POE::Loop::Event - a bridge that supports Event.pm from POE

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<Event>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
