# $Id$

# Gtk-Perl substrate for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Gtk;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other substrate module has been loaded.
BEGIN {
  die( "POE can't use Gtk and " . &POE_SUBSTRATE_NAME . "\n" )
    if defined &POE_SUBSTRATE;
};

use POE::Preprocessor;

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_GTK      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_GTK }

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  $poe_kernel->_enqueue_state
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_substrate_signal_handler_generic;
}

sub _substrate_signal_handler_pipe {
  $poe_kernel->_enqueue_state
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
  $poe_kernel->_enqueue_state
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
    $SIG{$signal} = \&_substrate_signal_handler_child;
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
  $SIG{CHLD} = \&_substrate_signal_handler_child if exists $SIG{CHLD};
  $SIG{CLD}  = \&_substrate_signal_handler_child if exists $SIG{CLD};
}

#------------------------------------------------------------------------------
# Watchers and callbacks.

macro substrate_resume_idle_watcher {
  $poe_kernel->[KR_WATCHER_IDLE] = Gtk->idle_add( \&_substrate_idle_callback )
    unless defined $poe_kernel->[KR_WATCHER_IDLE];
}

macro substrate_resume_alarm_watcher {
  my $next_time = ($poe_kernel->[KR_ALARMS]->[0]->[ST_TIME] - time()) * 1000;
  $next_time = 0 if $next_time < 0;
  $poe_kernel->[KR_WATCHER_TIMER] =
    Gtk->timeout_add( $next_time, \&_substrate_alarm_callback );
}

macro substrate_pause_alarm_watcher {
  # does nothing
}

macro substrate_watch_filehandle {
  # Overwriting a pre-existing watcher?
  if (defined $kr_handle->[HND_WATCHERS]->[$select_index]) {
    Gtk::Gdk->input_remove
      ( $kr_handle->[HND_WATCHERS]->[$select_index] );
    $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
  }

  # Register the new watcher.
  if ($select_index == VEC_RD) {
    $kr_handle->[HND_WATCHERS]->[VEC_RD] =
      Gtk::Gdk->input_add( fileno($handle), 'read',
                           \&_substrate_select_read_callback, $handle
                         );
  }
  elsif ($select_index == VEC_WR) {
    $kr_handle->[HND_WATCHERS]->[VEC_WR] =
      Gtk::Gdk->input_add( fileno($handle), 'write',
                           \&_substrate_select_write_callback, $handle
                         );
  }
  else {
    $kr_handle->[HND_WATCHERS]->[VEC_EX] =
      Gtk::Gdk->input_add( fileno($handle), 'exception',
                           \&_substrate_select_expedite_callback, $handle
                         );
  }
}

macro substrate_ignore_filehandle {
  # Don't bother removing a select if none was registered.
  if (defined $kr_handle->[HND_WATCHERS]->[$select_index]) {
    Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[$select_index] );
    $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
  }
}

macro substrate_pause_filehandle_write_watcher {
  my $kr_handle = $poe_kernel->[KR_HANDLES]->{$handle};
  Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[VEC_WR] );
  $kr_handle->[HND_WATCHERS]->[VEC_WR] = undef;
}

macro substrate_resume_filehandle_write_watcher {
  # Quietly ignore requests to resume unpaused handles.
  return 1
    if defined $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR];

  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR] =
    Gtk::Gdk->input_add( fileno($handle), 'write',
                         \&_substrate_select_write_callback, $handle
                       );
}

macro substrate_pause_filehandle_read_watcher {
  my $kr_handle = $poe_kernel->[KR_HANDLES]->{$handle};
  Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[VEC_RD] );
  $kr_handle->[HND_WATCHERS]->[VEC_RD] = undef;
}

macro substrate_resume_filehandle_read_watcher {
  # Quietly ignore requests to resume unpaused handles.
  return 1
    if defined $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD];

  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD] =
    Gtk::Gdk->input_add( fileno($handle), 'read',
                         \&_substrate_select_read_callback, $handle
                       );
}

macro substrate_define_callbacks {
  # Idle callback to dispatch FIFO states.
  sub _substrate_idle_callback {
    my $self = $poe_kernel;

    {% dispatch_one_from_fifo %}
    {% test_for_idle_poe_kernel %}

    # Perpetuate the Gtk idle callback if there's more to do.
    return 1 if @{$self->[KR_STATES]};

    # Otherwise stop it.
    $self->[KR_WATCHER_IDLE] = undef;
    return 0;
  }

  # Alarm callback to dispatch pending alarm states.
  sub _substrate_alarm_callback {
    my $self = $poe_kernel;

    {% dispatch_due_alarms %}
    {% test_for_idle_poe_kernel %}

    Gtk->timeout_remove( $self->[KR_WATCHER_TIMER] );
    $self->[KR_WATCHER_TIMER] = undef;

    # Register the next timeout if there are alarms left.
    if (@{$self->[KR_ALARMS]}) {
      my $next_time = ($self->[KR_ALARMS]->[0]->[ST_TIME] - time()) * 1000;
      $next_time = 0 if $next_time < 0;
      $self->[KR_WATCHER_TIMER] =
        Gtk->timeout_add( $next_time, \&_substrate_alarm_callback );
    }

    # Return false to stop.
    return 0;
  }

  # Filehandle callback to dispatch selects.
  sub _substrate_select_read_callback {
    my $self = $poe_kernel;
    my ($handle, $fileno, $hash) = @_;
    my $vector = VEC_RD;

    {% dispatch_ready_selects %}
    {% test_for_idle_poe_kernel %}

    # Return false to stop... probably not with this one.
    return 0;
  }

  sub _substrate_select_write_callback {
    my $self = $poe_kernel;
    my ($handle, $fileno, $hash) = @_;
    my $vector = VEC_WR;

    {% dispatch_ready_selects %}
    {% test_for_idle_poe_kernel %}

    # Return false to stop... probably not with this one.
    return 0;
  }

  sub _substrate_select_expedite_callback {
    my $self = $poe_kernel;
    my ($handle, $fileno, $hash) = @_;
    my $vector = VEC_EX;

    {% dispatch_ready_selects %}
    {% test_for_idle_poe_kernel %}

    # Return false to stop... probably not with this one.
    return 0;
  }
}

#------------------------------------------------------------------------------
# The event loop itself.

macro substrate_main_loop {
  Gtk->main;
}

macro substrate_stop_main_loop {
  $poe_main_window->destroy();
  Gtk->main_quit();
}

macro substrate_init_main_loop {
  Gtk->init;

  $poe_main_window = Gtk::Window->new('toplevel');
  die "could not create a main Gk window" unless defined $poe_main_window;

  $poe_main_window->signal_connect( delete_event => \&_signal_ui_destroy );
}

1;
