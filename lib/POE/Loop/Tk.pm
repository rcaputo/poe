# $Id$

# Tk-Perl event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Loop::Tk;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

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
my @_fileno_refcount;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  $poe_main_window = Tk::MainWindow->new();
  die "could not create a main Tk window" unless defined $poe_main_window;
  $self->signal_ui_destroy($poe_main_window);
}

sub loop_finalize {
  # does nothing
}

#------------------------------------------------------------------------------
# Signal handlers.

sub _loop_signal_handler_generic {
  TRACE_SIGNALS and warn "<sg> Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_data_ev_enqueue
    ( $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
      __FILE__, __LINE__, time(),
    );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  TRACE_SIGNALS and warn "<sg> Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_data_ev_enqueue
    ( $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
      __FILE__, __LINE__, time(),
    );
    $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _loop_signal_handler_child {
  TRACE_SIGNALS and warn "<sg> Enqueuing CHLD-like SIG$_[0] event...\n";
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_data_ev_enqueue
    ( $poe_kernel, $poe_kernel, EN_SCPOLL, ET_SCPOLL, [ ],
      __FILE__, __LINE__, time(),
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
    $self->_data_ev_enqueue
      ( $self, $self, EN_SCPOLL, ET_SCPOLL, [ ],
        __FILE__, __LINE__, time() + 1,
      ) if $signal eq 'CHLD' or not exists $SIG{CHLD};

    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_loop_signal_handler_pipe;
    return;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  return if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_loop_signal_handler_generic;
}

sub loop_ignore_signal {
  my ($self, $signal) = @_;
  $SIG{$signal} = "DEFAULT";
}

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

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 1 of 2.
  confess "Tk does not support expedited filehandles"
    if $mode == MODE_EX;

  # Start a filehandle watcher.

  $poe_main_window->fileevent
    ( $handle,

      # It can only be MODE_RD or MODE_WR here (MODE_EX is checked a
      # few lines up).
      ( $mode == MODE_RD ) ? 'readable' : 'writable',

      # The handle is wrapped in quotes here to stringify it.  For
      # some reason, it seems to work as a filehandle anyway, and it
      # breaks reference counting.  For filehandles, then, this is
      # truly a safe (strict ok? warn ok? seems so!) weak reference.
      [ \&_loop_select_callback, $fileno, $mode ],
    );

  $_fileno_refcount[fileno $handle]++;
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $mode == MODE_EX;

  # The fileno refcount just dropped to 0.  Remove the handle from
  # Tk's file watchers.

  unless (--$_fileno_refcount[fileno $handle]) {
    $poe_main_window->fileevent
      ( $handle,

        # It can only be MODE_RD or MODE_WR here (MODE_EX is checked a
        # few lines up).
        ( ( $mode == MODE_RD ) ? 'readable' : 'writable' ),

        # Nothing here!  Callback all gone!
        ''
      );
  }

  # Otherwise we have other things watching the handle.  Go into Tk's
  # undocumented guts to disable just this watcher without hosing the
  # entire fileevent thing.

  else {
    my $tk_file_io = tied( *$handle );
    die "whoops; no tk file io object" unless defined $tk_file_io;
    $tk_file_io->handler
      ( ( ( $mode == MODE_RD )
          ? Tk::Event::IO::READABLE()
          : Tk::Event::IO::WRITABLE()
        ),
        ''
      );
  }
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $mode == MODE_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( ( ( $mode == MODE_RD )
                          ? Tk::Event::IO::READABLE()
                          : Tk::Event::IO::WRITABLE()
                        ),
                        ''
                      );
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $mode == MODE_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;

  $tk_file_io->handler( ( ( $mode == MODE_RD )
                          ? Tk::Event::IO::READABLE()
                          : Tk::Event::IO::WRITABLE()
                        ),
                        [ \&_loop_select_callback,
                          $fileno,
                          $mode,
                        ]
                      );
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

# Tk filehandle callback to dispatch selects.
sub _loop_select_callback {
  my ($fileno, $mode) = @_;
  $poe_kernel->_data_handle_enqueue_ready($mode, $fileno);
  $poe_kernel->_test_if_kernel_is_idle();
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
  warn "Tk::Error: $error\n " . join("\n ",@_)."\n";

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

POE::Loop::Event - a bridge that supports Tk's event loop from POE

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
