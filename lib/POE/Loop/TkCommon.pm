# $Id$

# The common bits of our system-specific Tk event loops.  This is
# everything but file handling.

# Empty package to appease perl.
package POE::Loop::TkCommon;

# Include common signal handling.
use POE::Loop::PerlSignals;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

BEGIN {
  die "POE's Tk support requires version Tk 800.021 or higher.\n"
    unless defined($Tk::VERSION) and $Tk::VERSION >= 800.021;
  die "POE's Tk support requires Perl 5.005_03 or later.\n"
    if $] < 5.00503;
};

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Delcare which event loop bridge is being used, but first ensure that
# no other bridge has been loaded.

BEGIN {
  die( "POE can't use Tk and " . &POE_LOOP_NAME . "\n" )
    if defined &POE_LOOP;
};

sub POE_LOOP () { LOOP_TK }

my $_watcher_timer;

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_attach_uidestroy {
  my ($self, $window) = @_;

  $window->OnDestroy
    ( sub {
        if ($self->_data_ses_count()) {
          $self->_dispatch_event
            ( $self, $self,
              EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
              __FILE__, __LINE__, time(), -__LINE__
            );
        }
      }
    );
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  my ($self, $next_time) = @_;
  $next_time -= time();

  if (defined $_watcher_timer) {
    $_watcher_timer->cancel();
    undef $_watcher_timer;
  }

  $next_time = 0 if $next_time < 0;
  $_watcher_timer =
    $poe_main_window->after($next_time * 1000, [\&_loop_event_callback]);
}

sub loop_reset_time_watcher {
  my ($self, $next_time) = @_;
  $self->loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
  my $self = shift;
  $_watcher_timer->stop() if defined $_watcher_timer;
}

# Tk's alarm callbacks seem to have the highest priority.  That is, if
# $widget->after is constantly scheduled for a period smaller than the
# overhead of dispatching it, then no other events are processed.
# That includes afterIdle and even internal Tk events.

# Tk timer callback to dispatch events.
sub _loop_event_callback {
  $poe_kernel->_data_ev_dispatch_due();

  # As was mentioned before, $widget->after() events can dominate a
  # program's event loop, starving it of other events, including Tk's
  # internal widget events.  To avoid this, we'll reset the event
  # callback from an idle event.

  # Register the next timed callback if there are events left.

  if ($poe_kernel->get_event_count()) {

    # Cancel the Tk alarm that handles alarms.

    if (defined $_watcher_timer) {
      $_watcher_timer->cancel();
      undef $_watcher_timer;
    }

    # Replace it with an idle event that will reset the alarm.

    $_watcher_timer =
      $poe_main_window->afterIdle
        ( [ sub {
              $_watcher_timer->cancel();
              undef $_watcher_timer;

              my $next_time = $poe_kernel->get_next_event_time();
              if (defined $next_time) {
                $next_time -= time();
                $next_time = 0 if $next_time < 0;

                $_watcher_timer =
                  $poe_main_window->after( $next_time * 1000,
                                           [\&_loop_event_callback]
                                         );
              }
            }
          ],
        );

    # POE::Kernel's signal polling loop always keeps one event in the
    # queue.  We test for an idle kernel if the queue holds only one
    # event.  A more generic method would be to keep counts of user
    # vs. kernel events, and GC the kernel when the user events drop
    # to 0.

    if ($poe_kernel->get_event_count() == 1) {
      $poe_kernel->_test_if_kernel_is_idle();
    }
  }

  # Make sure the kernel can still run.
  else {
    $poe_kernel->_test_if_kernel_is_idle();
  }
}

#------------------------------------------------------------------------------
# Tk traps errors in an effort to survive them.  However, since POE
# does not, this leaves us in a strange, inconsistent state.  Here we
# re-trap the errors and rethrow them as UIDESTROY.

sub Tk::Error {
  my $window = shift;
  my $error  = shift;

  if (Tk::Exists($window)) {
    my $grab = $window->grab('current');
    $grab->Unbusy if defined $grab;
  }
  chomp($error);
  POE::Kernel::_warn "Tk::Error: $error\n " . join("\n ",@_)."\n";

  if ($poe_kernel->_data_ses_count()) {
    $poe_kernel->_dispatch_event
      ( $poe_kernel, $poe_kernel,
        EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
        __FILE__, __LINE__, time(), -__LINE__
      );
  }
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  die "doing timeslices currently not supported in the Tk loop";
}

sub loop_run {
  Tk::MainLoop();
}

sub loop_halt {
  undef $_watcher_timer;
  $poe_main_window->destroy();
}

1;

__END__

=head1 NAME

POE::Loop::TkCommon - common features of POE's Tk event loop bridges

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<Tk>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
