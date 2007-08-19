# $Id$

# Event.pm event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Loop::Event;

use strict;

# Include common signal handling.  Signals should be safe now, and for
# some reason Event isn't dispatching SIGCHLD to me circa POE r2084.
use POE::Loop::PerlSignals;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

=for poe_tests

sub skip_tests {
  return "Event tests require the Event module" if (
    do { eval "use Event"; $@ }
  );
  my $test_name = shift;
  if ($test_name eq "k_signals_rerun" and $^O eq "MSWin32") {
    return "This test crashes Perl when run with Tk on $^O";
  }
}

=cut

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

my $_watcher_timer;
my @fileno_watcher;
my %signal_watcher;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  $_watcher_timer = Event->timer(
    cb     => \&_loop_event_callback,
    after  => 0,
  );
}

sub loop_finalize {
  my $self = shift;

  foreach my $fd (0..$#fileno_watcher) {
    next unless defined $fileno_watcher[$fd];
    foreach my $mode (MODE_RD, MODE_WR, MODE_EX) {
      POE::Kernel::_warn(
        "Mode $mode watcher for fileno $fd is defined during loop finalize"
      ) if defined $fileno_watcher[$fd]->[$mode];
    }
  }

  $self->loop_ignore_all_signals();
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_attach_uidestroy {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  my ($self, $next_time) = @_;
  ($_watcher_timer and $next_time) or return;
  $_watcher_timer->at($next_time);
  $_watcher_timer->start();
}

sub loop_reset_time_watcher {
  my ($self, $next_time) = @_;
  $_watcher_timer or return;
  $self->loop_pause_time_watcher();
  $self->loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
  $_watcher_timer or return;
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
  Event::one_event();
}

sub loop_run {
  my $self = shift;
  while ($self->_data_ses_count()) {
    $self->loop_do_timeslice();
  }
}

sub loop_halt {
  $_watcher_timer->stop();
  $_watcher_timer = undef;
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

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Redocument.
