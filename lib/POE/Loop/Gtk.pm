# $Id$

# Gtk-Perl substrate for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Gtk;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel.
package POE::Kernel;
use POE::Preprocessor;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Ensure that no other substrate module has been loaded.
BEGIN {
  die( "POE can't use Gtk and " . &POE_SUBSTRATE_NAME . "\n" )
    if defined &POE_SUBSTRATE;
};

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_GTK      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_GTK }

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_substrate_signal_handler_generic;
}

sub _substrate_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
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
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance macros.

macro substrate_watch_signal {
  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # For SIGCHLD triggered polling loop.
    # $SIG{$signal} = \&_substrate_signal_handler_child;

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $poe_kernel->_enqueue_event
      ( $poe_kernel, $poe_kernel,
        EN_SCPOLL, ET_SCPOLL,
        [ ],
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
  # For SIGCHLD triggered polling loop.
  # $SIG{CHLD} = \&_substrate_signal_handler_child if exists $SIG{CHLD};
  # $SIG{CLD}  = \&_substrate_signal_handler_child if exists $SIG{CLD};

  # For constant polling loop.
  $SIG{CHLD} = 'DEFAULT' if exists $SIG{CHLD};
  $SIG{CLD}  = 'DEFAULT' if exists $SIG{CLD};
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%kr_sessions) > 1;
}

#------------------------------------------------------------------------------
# Watchers and callbacks.

### Time.

macro substrate_resume_time_watcher {
  my $next_time = ($kr_events[0]->[ST_TIME] - time()) * 1000;
  $next_time = 0 if $next_time < 0;
  $poe_kernel->[KR_WATCHER_TIMER] =
    Gtk->timeout_add( $next_time, \&_substrate_event_callback );
}

macro substrate_reset_time_watcher {
  # Should always be defined, right?
  Gtk->timeout_remove( $self->[KR_WATCHER_TIMER] );
  $self->[KR_WATCHER_TIMER] = undef;
  {% substrate_resume_time_watcher %}
}

macro substrate_pause_time_watcher {
  # does nothing
}

### Filehandles.

macro substrate_watch_filehandle (<fileno>,<vector>) {
  # Overwriting a pre-existing watcher?
  if (defined $kr_fno_vec->[FVC_WATCHER]) {
    Gtk::Gdk->input_remove( $kr_fno_vec->[FVC_WATCHER] );
    $kr_fno_vec->[FVC_WATCHER] = undef;
  }

  # Register the new watcher.
  $kr_fno_vec->[FVC_WATCHER] =
    Gtk::Gdk->input_add( <fileno>,
                         ( (<vector> == VEC_RD)
                           ? ( 'read',
                               \&_substrate_select_read_callback
                             )
                           : ( (<vector> == VEC_WR)
                               ? ( 'write',
                                   \&_substrate_select_write_callback
                                 )
                               : ( 'exception',
                                   \&_substrate_select_expedite_callback
                                 )
                             )
                         ),
                         <fileno>
                       );

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

macro substrate_ignore_filehandle (<fileno>,<vector>) {
  # Don't bother removing a select if none was registered.
  if (defined $kr_fno_vec->[FVC_WATCHER]) {
    Gtk::Gdk->input_remove( $kr_fno_vec->[FVC_WATCHER] );
    $kr_fno_vec->[FVC_WATCHER] = undef;
  }
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}

macro substrate_pause_filehandle_watcher (<fileno>,<vector>) {
  Gtk::Gdk->input_remove( $kr_fno_vec->[FVC_WATCHER] );
  $kr_fno_vec->[FVC_WATCHER] = undef;
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

macro substrate_resume_filehandle_watcher (<fileno>,<vector>) {
  # Quietly ignore requests to resume unpaused handles.
  return 1 if defined $kr_fno_vec->[FVC_WATCHER];

  $kr_fno_vec->[FVC_WATCHER] =
    Gtk::Gdk->input_add( <fileno>,
                         ( (<vector> == VEC_RD)
                           ? ( 'read',
                               \&_substrate_select_read_callback
                             )
                           : ( (<vector> == VEC_WR)
                               ? ( 'write',
                                   \&_substrate_select_write_callback
                                 )
                               : ( 'exception',
                                   \&_substrate_select_expedite_callback
                                 )
                             )
                         ),
                         <fileno>
                       );
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

### Callbacks.

macro substrate_define_callbacks {

  # Event callback to dispatch pending events.
  sub _substrate_event_callback {
    my $self = $poe_kernel;

    {% dispatch_due_events %}
    {% test_for_idle_poe_kernel %}

    Gtk->timeout_remove( $self->[KR_WATCHER_TIMER] );
    $self->[KR_WATCHER_TIMER] = undef;

    # Register the next timeout if there are events left.
    if (@kr_events) {
      my $next_time = ($kr_events[0]->[ST_TIME] - time()) * 1000;
      $next_time = 0 if $next_time < 0;
      $self->[KR_WATCHER_TIMER] =
        Gtk->timeout_add( $next_time, \&_substrate_event_callback );
    }

    # Return false to stop.
    return 0;
  }

  # Filehandle callback to dispatch selects.
  sub _substrate_select_read_callback {
    my $self = $poe_kernel;
    my ($handle, $fileno, $hash) = @_;

    {% enqueue_ready_selects $fileno, VEC_RD %}
    {% test_for_idle_poe_kernel %}

    # Return false to stop... probably not with this one.
    return 0;
  }

  sub _substrate_select_write_callback {
    my $self = $poe_kernel;
    my ($handle, $fileno, $hash) = @_;

    {% enqueue_ready_selects $fileno, VEC_WR %}
    {% test_for_idle_poe_kernel %}

    # Return false to stop... probably not with this one.
    return 0;
  }

  sub _substrate_select_expedite_callback {
    my $self = $poe_kernel;
    my ($handle, $fileno, $hash) = @_;

    {% enqueue_ready_selects $fileno, VEC_EX %}
    {% test_for_idle_poe_kernel %}

    # Return false to stop... probably not with this one.
    return 0;
  }
}

#------------------------------------------------------------------------------
# The event loop itself.

# ???
macro substrate_do_timeslice {
  die "doing timeslices currently not supported in the Gtk substrate";
}

macro substrate_main_loop {
  Gtk->main;
}

macro substrate_stop_main_loop {
  Gtk->main_quit();
}

macro substrate_init_main_loop {
  Gtk->init;
}

# This function sets us up a signal when whichever window is passed to
# it closes.
sub signal_ui_destroy {
  my ($self, $window) = @_;

  # Don't bother posting the signal if there are no sessions left.  I
  # think this is a bit of a kludge: the situation where a window
  # lasts longer than POE::Kernel should never occur.
  $window->signal_connect
    ( delete_event =>
      sub {
        if (keys %{$self->[KR_SESSIONS]}) {
          $self->_dispatch_event
            ( $self, $self,
              EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
              time(), __FILE__, __LINE__, undef
            );
        }
        return undef;
      }
    );
}

1;
