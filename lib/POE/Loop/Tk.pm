# $Id$

# Tk-Perl substrate for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Tk;

# Bogus version to appease perl, otherwise it finds the next "unless"
# statement, and CPAN.pm fails.
use vars qw($VERSION);
$VERSION = '0.00';

BEGIN {
  die "POE's Tk support requires version Tk 800.021 or higher.\n"
    unless defined($Tk::VERSION) and $Tk::VERSION >= 800.021;
};

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other substrate module has been loaded.
BEGIN {
  die( "POE can't use Tk and " . &POE_SUBSTRATE_NAME . "\n" )
    if defined &POE_SUBSTRATE;
};

use POE::Preprocessor;

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_TK      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_TK }

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_substrate_signal_handler_generic;
}

sub _substrate_signal_handler_pipe {
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_substrate_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _substrate_signal_handler_child {
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL, [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance macros.

macro substrate_watch_signal {
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

    next;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_substrate_signal_handler_pipe;
    next;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  next if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_substrate_signal_handler_generic;
}

macro substrate_resume_watching_child_signals () {
  $SIG{CHLD} = 'DEFAULT' if exists $SIG{CHLD};
  $SIG{CLD}  = 'DEFAULT' if exists $SIG{CLD};
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL, [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%kr_sessions) > 1;
}

#------------------------------------------------------------------------------
# Watchers and callbacks.

### Time.

macro substrate_resume_time_watcher {
  if (defined $self->[KR_WATCHER_TIMER]) {
    $self->[KR_WATCHER_TIMER]->cancel();
    $self->[KR_WATCHER_TIMER] = undef;
  }

  my $next_time = $kr_events[0]->[ST_TIME] - time();
  $next_time = 0 if $next_time < 0;
  $self->[KR_WATCHER_TIMER] =
    $poe_main_window->after( $next_time * 1000, \&_substrate_event_callback );
}

macro substrate_reset_time_watcher {
  {% substrate_resume_time_watcher %}
}

macro substrate_pause_time_watcher {
  $self->[KR_WATCHER_TIMER]->stop()
    if defined $self->[KR_WATCHER_TIMER];
}

### Filehandles.

macro substrate_watch_filehandle (<fileno>,<vector>) {
  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 1 of 2.
  confess "Tk does not support expedited filehandles"
    if <vector> == VEC_EX;

  # Cheat.  $handle comes from the user's scope.

  $poe_main_window->fileevent
    ( $handle,

      # It can only be VEC_RD or VEC_WR here (VEC_EX is checked a few
      # lines up).
      ( <vector> == VEC_RD ) ? 'readable' : 'writable',

      # The handle is wrapped in quotes here to stringify it.  For
      # some reason, it seems to work as a filehandle anyway, and it
      # breaks reference counting.  For filehandles, then, this is
      # truly a safe (strict ok? warn ok? seems so!) weak reference.
      [ \&_substrate_select_callback, <fileno>, <vector> ],
    );

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

macro substrate_ignore_filehandle (<fileno>,<vector>) {
  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if <vector> == VEC_EX;

  # Total handle refcount is 1.  This handle is going away for good,
  # so we can use fileevent to close it.  This does an untie/undef
  # within Tk, which is why it shouldn't be done for higher refcounts.

  if ($kr_fileno->[FNO_TOT_REFCOUNT] == 1) {
    $poe_main_window->fileevent
      ( $handle,

        # It can only be VEC_RD or VEC_WR here (VEC_EX is checked a
        # few lines up).
        ( ( <vector> == VEC_RD ) ? 'readable' : 'writable' ),

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
      ( ( ( <vector> == VEC_RD )
          ? Tk::Event::IO::READABLE()
          : Tk::Event::IO::WRITABLE()
        ),
        ''
      );
  }

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}

macro substrate_pause_filehandle_watcher (<fileno>,<vector>) {
  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if <vector> == VEC_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( ( ( <vector> == VEC_RD )
                          ? Tk::Event::IO::READABLE()
                          : Tk::Event::IO::WRITABLE()
                        ),
                        ''
                      );
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

macro substrate_resume_filehandle_watcher (<fileno>,<vector>) {
  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if <vector> == VEC_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;

  $tk_file_io->handler( ( ( <vector> == VEC_RD )
                          ? Tk::Event::IO::READABLE()
                          : Tk::Event::IO::WRITABLE()
                        ),
                        [ \&_substrate_select_callback,
                          <fileno>,
                          <vector>,
                        ]
                      );
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

macro substrate_define_callbacks {
  # Tk's alarm callbacks seem to have the highest priority.  That is,
  # if $widget->after is constantly scheduled for a period smaller
  # than the overhead of dispatching it, then no other events are
  # processed.  That includes afterIdle and even internal Tk events.

  # Tk timer callback to dispatch events.
  sub _substrate_event_callback {
    my $self = $poe_kernel;

    {% dispatch_due_events %}

    # As was mentioned before, $widget->after() events can dominate a
    # program's event loop, starving it of other events, including
    # Tk's internal widget events.  To avoid this, we'll reset the
    # event callback from an idle event.

    # Register the next timed callback if there are events left.

    if (@kr_events) {

      # Cancel the Tk alarm that handles alarms.

      if (defined $self->[KR_WATCHER_TIMER]) {
        $self->[KR_WATCHER_TIMER]->cancel();
        $self->[KR_WATCHER_TIMER] = undef;
      }

      # Replace it with an idle event that will reset the alarm.

      $self->[KR_WATCHER_TIMER] =
        $poe_main_window->afterIdle
          ( sub {
              $self->[KR_WATCHER_TIMER]->cancel();
              $self->[KR_WATCHER_TIMER] = undef;

              if (@kr_events) {
                my $next_time = $kr_events[0]->[ST_TIME] - time();
                $next_time = 0 if $next_time < 0;

                $self->[KR_WATCHER_TIMER] =
                  $poe_main_window->after( $next_time * 1000,
                                           \&_substrate_event_callback
                                         );
              }
            }
          );
    }

    # Make sure the kernel can still run.
    else {
      {% test_for_idle_poe_kernel %}
    }
  }

  # Tk filehandle callback to dispatch selects.
  sub _substrate_select_callback {
    my ($fileno, $vector) = @_;
    {% enqueue_ready_selects $fileno, $vector %}
    {% test_for_idle_poe_kernel %}
  }
}

### Errors.

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

# ???
macro substrate_do_timeslice {
  die "doing timeslices currently not supported in the Tk substrate";
}

macro substrate_main_loop {
  Tk::MainLoop();
}

macro substrate_stop_main_loop {
  $self->[KR_WATCHER_TIMER] = undef;
  $poe_main_window->destroy();
}

macro substrate_init_main_loop {
  $poe_main_window = Tk::MainWindow->new();
  die "could not create a main Tk window" unless defined $poe_main_window;
  $poe_kernel->signal_ui_destroy( $poe_main_window );
}

sub signal_ui_destroy {
  my ($self, $window) = @_;
  $window->OnDestroy
    ( sub {
        if (keys %{$self->[KR_SESSIONS]}) {
          $self->_dispatch_event
            ( $self, $self,
              EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
              time(), __FILE__, __LINE__, undef
            );
        }
      }
    );
}

1;
