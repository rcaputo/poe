# $Id$

# Tk-Perl event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Tk;

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

my ($kr_sessions, $kr_events, $kr_filenos);

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $kernel = shift;
  $kr_sessions = $kernel->_get_kr_sessions_ref();
  $kr_events   = $kernel->_get_kr_events_ref();
  $kr_filenos  = $kernel->_get_kr_filenos_ref();

  $poe_main_window = Tk::MainWindow->new();
  die "could not create a main Tk window" unless defined $poe_main_window;
  $poe_kernel->signal_ui_destroy( $poe_main_window );
}

sub loop_finalize {
  # does nothing
}

#------------------------------------------------------------------------------
# Signal handlers.

sub _loop_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _loop_signal_handler_child {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL, [ ],
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
        EN_SCPOLL, ET_SCPOLL, [ ],
        time() + 1, __FILE__, __LINE__
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

sub loop_resume_watching_child_signals () {
  $SIG{CHLD} = 'DEFAULT' if exists $SIG{CHLD};
  $SIG{CLD}  = 'DEFAULT' if exists $SIG{CLD};
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL, [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%$kr_sessions) > 1;
}

sub loop_ignore_signal {
  my $signal = shift;
  $SIG{$signal} = "DEFAULT";
}

sub loop_attach_uidestroy {
  my ($poe_kernel, $window) = @_;
  $window->OnDestroy
    ( sub {
        if (keys %{$poe_kernel->[KR_SESSIONS]}) {
          $poe_kernel->_dispatch_event
            ( $poe_kernel, $poe_kernel,
              EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
              time(), __FILE__, __LINE__, undef
            );
        }
      }
    );
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  my $next_time = shift() - time();

  if (defined $_watcher_timer) {
    $_watcher_timer->cancel();
    undef $_watcher_timer;
  }

  $next_time = 0 if $next_time < 0;
  $_watcher_timer =
    $poe_main_window->after($next_time * 1000, [\&_loop_event_callback]);
}

sub loop_reset_time_watcher {
  my $next_time = shift;
  loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
  $_watcher_timer->stop() if defined $_watcher_timer;
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 1 of 2.
  confess "Tk does not support expedited filehandles"
    if $vector == VEC_EX;

  # Cheat.  $handle comes from the user's scope.

  $poe_main_window->fileevent
    ( $handle,

      # It can only be VEC_RD or VEC_WR here (VEC_EX is checked a few
      # lines up).
      ( $vector == VEC_RD ) ? 'readable' : 'writable',

      # The handle is wrapped in quotes here to stringify it.  For
      # some reason, it seems to work as a filehandle anyway, and it
      # breaks reference counting.  For filehandles, then, this is
      # truly a safe (strict ok? warn ok? seems so!) weak reference.
      [ \&_loop_select_callback, $fileno, $vector ],
    );

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

sub loop_ignore_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $vector == VEC_EX;

  # Total handle refcount is 1.  This handle is going away for good,
  # so we can use fileevent to close it.  This does an untie/undef
  # within Tk, which is why it shouldn't be done for higher refcounts.

  if ($kr_filenos->{fileno($handle)}->[FNO_TOT_REFCOUNT] == 1) {
    $poe_main_window->fileevent
      ( $handle,

        # It can only be VEC_RD or VEC_WR here (VEC_EX is checked a
        # few lines up).
        ( ( $vector == VEC_RD ) ? 'readable' : 'writable' ),

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
      ( ( ( $vector == VEC_RD )
          ? Tk::Event::IO::READABLE()
          : Tk::Event::IO::WRITABLE()
        ),
        ''
      );
  }

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}

sub loop_pause_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $vector == VEC_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( ( ( $vector == VEC_RD )
                          ? Tk::Event::IO::READABLE()
                          : Tk::Event::IO::WRITABLE()
                        ),
                        ''
                      );
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

sub loop_resume_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $vector == VEC_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;

  $tk_file_io->handler( ( ( $vector == VEC_RD )
                          ? Tk::Event::IO::READABLE()
                          : Tk::Event::IO::WRITABLE()
                        ),
                        [ \&_loop_select_callback,
                          $fileno,
                          $vector,
                        ]
                      );
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

# Tk's alarm callbacks seem to have the highest priority.  That is, if
# $widget->after is constantly scheduled for a period smaller than the
# overhead of dispatching it, then no other events are processed.
# That includes afterIdle and even internal Tk events.

# Tk timer callback to dispatch events.
sub _loop_event_callback {
  my $poe_kernel = $poe_kernel;

  dispatch_due_events();

  # As was mentioned before, $widget->after() events can dominate a
  # program's event loop, starving it of other events, including Tk's
  # internal widget events.  To avoid this, we'll reset the event
  # callback from an idle event.

  # Register the next timed callback if there are events left.

  if (@$kr_events) {

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

              if (@$kr_events) {
                my $next_time = $kr_events->[0]->[ST_TIME] - time();
                $next_time = 0 if $next_time < 0;

                $_watcher_timer =
                  $poe_main_window->after( $next_time * 1000,
                                           [\&_loop_event_callback]
                                         );
              }
            }
          ],
        );

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

# Tk filehandle callback to dispatch selects.
sub _loop_select_callback {
  my ($fileno, $vector) = @_;
  enqueue_ready_selects($vector, $fileno);
  test_for_idle_poe_kernel();
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

  if (keys %{$poe_kernel->[KR_SESSIONS]}) {
    $poe_kernel->_dispatch_event
      ( $poe_kernel, $poe_kernel,
        EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
        time(), __FILE__, __LINE__, undef
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
