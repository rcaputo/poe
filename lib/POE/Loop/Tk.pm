# $Id$

# Tk-Perl personality module for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Tk;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other personality module has been loaded.
BEGIN {
  die( "POE can't use Tk and " . &POE_PERSONALITY_NAME . "\n" )
    if defined &POE_PERSONALITY;
};

use POE::Preprocessor;

# Declare the personality we're using.
sub POE_PERSONALITY      () { PERSONALITY_TK      }
sub POE_PERSONALITY_NAME () { PERSONALITY_NAME_TK }

#------------------------------------------------------------------------------
# Define signal handlers and the functions that watch them.

sub _signal_handler_generic {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_signal_handler_generic;
}

sub _signal_handler_pipe {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _signal_handler_child {
  $SIG{$_[0]} = 'DEFAULT';
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
    $SIG{$signal} = \&_signal_handler_child;
    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_signal_handler_pipe;
    return;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  return if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_signal_handler_generic;
}

sub _resume_watching_child_signals () {
  $SIG{CHLD} = \&_signal_handler_child if exists $SIG{CHLD};
  $SIG{CLD}  = \&_signal_handler_child if exists $SIG{CLD};
}

#------------------------------------------------------------------------------
# Watchers and callbacks.

sub _resume_idle_watcher {
  $poe_kernel->[KR_WATCHER_IDLE] =
    $poe_main_window->afterIdle( \&_idle_callback );
}

sub _resume_alarm_watcher {
  if (defined $poe_kernel->[KR_WATCHER_TIMER]) {
    $poe_kernel->[KR_WATCHER_TIMER]->cancel();
    $poe_kernel->[KR_WATCHER_TIMER] = undef;
  }

  my $next_time = $poe_kernel->[KR_ALARMS]->[0]->[ST_TIME] - time();
  $next_time = 0 if $next_time < 0;
  $poe_kernel->[KR_WATCHER_TIMER] =
    $poe_main_window->after( $next_time * 1000, \&_alarm_callback );
}

sub _pause_alarm_watcher {
  $poe_kernel->[KR_WATCHER_TIMER]->stop();
}

sub _watch_filehandle {
  my ($kr_handle, $handle, $select_index) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 1 of 2.
  confess "Tk does not support expedited filehandles"
    if $select_index == VEC_EX;

  my $direction =
    ( 
    );
  Tk::Event::IO->fileevent
    ( $handle,

      # It can only be VEC_RD or VEC_WR here (VEC_EX is checked a few
      # lines up).
      ( $select_index == VEC_RD ) ? 'readable' : 'writable',

      [ \&_select_callback, $handle, $select_index ],
    );
}

sub _ignore_filehandle {
  my ($kr_handle, $handle, $select_index) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $select_index == VEC_EX;

  # Handle refcount is 1; this handle is going away for good.  We can
  # use fileevent to close it, which will do untie/undef within Tk.
  if ($kr_handle->[HND_REFCOUNT] == 1) {
    Tk::Event::IO->fileevent
      ( $handle,

        # It can only be VEC_RD or VEC_WR here (VEC_EX is checked a
        # few lines up).
        ( ( $select_index == VEC_RD ) ? 'readable' : 'writable' ),

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
      ( ( ( $select_index == VEC_RD )
          ? Tk::Event::IO::READABLE()
          : Tk::Event::IO::WRITABLE()
        ),
        ''
      );
  }
}

sub _pause_filehandle_write_watcher {
  my $handle = shift;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( Tk::Event::IO::WRITABLE(), '' );
}

sub _resume_filehandle_write_watcher {
  my $handle = shift;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( Tk::Event::IO::WRITABLE(),
                        [ \&_select_callback, $handle, VEC_WR ]
                      );
}

sub _pause_filehandle_read_watcher {
  my $handle = shift;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( Tk::Event::IO::READABLE(), '' );
}

sub _resume_filehandle_read_watcher {
  my $handle = shift;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;
  $tk_file_io->handler( Tk::Event::IO::READABLE(),
                        [ \&_select_callback, $handle, VEC_RD ]
                      );
}

# Tk's alarm callbacks seem to have the highest priority.  That is, if
# $widget->after is constantly scheduled for a period smaller than the
# overhead of dispatching it, then no other events are processed.
# That includes afterIdle and even internal Tk events.

# This is the idle callback to dispatch FIFO states.

sub _idle_callback {
  my $self = $poe_kernel;

  _dispatch_one_from_fifo();

  # Perpetuate the dispatch loop as long as there are states enqueued.

  if (defined $self->[KR_WATCHER_IDLE]) {
    $self->[KR_WATCHER_IDLE]->cancel();
    $self->[KR_WATCHER_IDLE] = undef;
  }

  # This nasty little hack is required because setting an afterIdle
  # from a running afterIdle effectively blocks OS/2 Presentation
  # Manager events.  This locks up its notion of a window manager.  I
  # couldn't get anyone to test it on other platforms... (Hey, this could
  # trash yoru desktop! Wanna try it?) :)

  if (@{$self->[KR_STATES]}) {
    $poe_main_window->after
      ( 0,
        sub {
          $self->[KR_WATCHER_IDLE] =
            $poe_main_window->afterIdle( \&_idle_callback )
          unless defined $self->[KR_WATCHER_IDLE];
        }
      );
  }

  # Make sure the kernel can still run.
  else {
    _test_for_idle_poe_kernel();
  }
}

# Tk timer callback to dispatch alarm states.  Same caveats about
# macro-izing this code.

sub _alarm_callback {
  my $self = $poe_kernel;

  _dispatch_due_alarms();

  # As was mentioned before, $widget->after() events can dominate a
  # program's event loop, starving it of other events, including Tk's
  # internal widget events.  To avoid this, we'll reset the alarm
  # callback from an idle event.

  # Register the next timed callback if there are alarms left.

  if (@{$self->[KR_ALARMS]}) {

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

            if (@{$self->[KR_ALARMS]}) {
              my $next_time = $self->[KR_ALARMS]->[0]->[ST_TIME] - time();
              $next_time = 0 if $next_time < 0;

              $self->[KR_WATCHER_TIMER] =
                $poe_main_window->after( $next_time * 1000,
                                         \&_alarm_callback
                                       );
            }
          }
        );
  }

  # Make sure the kernel can still run.
  else {
    _test_for_idle_poe_kernel();
  }
}

# Tk filehandle callback to dispatch selects.

sub _select_callback {
  my ($handle, $vector) = @_;
  _dispatch_ready_selects( $handle, $vector );
  _test_for_idle_poe_kernel();
}

#------------------------------------------------------------------------------
# The event loop itself.

sub _start_main_loop {
  Tk::MainLoop();
}

sub _stop_main_loop {
  my $self = shift;
  $self->[KR_WATCHER_IDLE]  = undef;
  $self->[KR_WATCHER_TIMER] = undef;
  $poe_main_window->destroy();
}

sub _init_main_loop {
  $poe_main_window = Tk::MainWindow->new();
  die "could not create a main Tk window" unless defined $poe_main_window;

  $poe_main_window->OnDestroy( \&signal_ui_destroy );
}

1;
