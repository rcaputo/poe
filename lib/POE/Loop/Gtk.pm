# $Id$

# Gtk-Perl personality module for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Gtk;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other personality module has been loaded.
BEGIN {
  die( "POE can't use Gtk and " . &POE_PERSONALITY_NAME . "\n" )
    if defined &POE_PERSONALITY;
};

use POE::Preprocessor;

# Declare the personality we're using.
sub POE_PERSONALITY      () { PERSONALITY_GTK      }
sub POE_PERSONALITY_NAME () { PERSONALITY_NAME_GTK }

#------------------------------------------------------------------------------
# Define signal handlers and the functions that define them.

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
  $poe_kernel->[KR_WATCHER_IDLE] = Gtk->idle_add( \&_idle_callback )
    unless defined $poe_kernel->[KR_WATCHER_IDLE];
}

sub _resume_alarm_watcher {
  my $next_time = ($poe_kernel->[KR_ALARMS]->[0]->[ST_TIME] - time()) * 1000;
  $next_time = 0 if $next_time < 0;
  $poe_kernel->[KR_WATCHER_TIMER] =
    Gtk->timeout_add( $next_time, \&_alarm_callback );
}

sub _pause_alarm_watcher () { }

sub _watch_filehandle {
  my ($kr_handle, $handle, $select_index) = @_;

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
                           \&_select_read_callback, $handle
                         );
  }
  elsif ($select_index == VEC_WR) {
    $kr_handle->[HND_WATCHERS]->[VEC_WR] =
      Gtk::Gdk->input_add( fileno($handle), 'write',
                           \&_select_write_callback, $handle
                         );
  }
  else {
    $kr_handle->[HND_WATCHERS]->[VEC_EX] =
      Gtk::Gdk->input_add( fileno($handle), 'exception',
                           \&_select_expedite_callback, $handle
                         );
  }
}

sub _ignore_filehandle {
  my ($kr_handle, $handle, $select_index) = @_;

  # Don't bother removing a select if none was registered.
  if (defined $kr_handle->[HND_WATCHERS]->[$select_index]) {
    Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[$select_index] );
    $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
  }
}

sub _pause_filehandle_write_watcher {
  my $handle = shift;
  my $kr_handle = $poe_kernel->[KR_HANDLES]->{$handle};
  Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[VEC_WR] );
  $kr_handle->[HND_WATCHERS]->[VEC_WR] = undef;
}

sub _resume_filehandle_write_watcher {
  my $handle = shift;

  # Quietly ignore requests to resume unpaused handles.
  return 1
    if defined $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR];

  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR] =
    Gtk::Gdk->input_add( fileno($handle), 'write',
                         \&_select_write_callback, $handle
                       );
}

sub _pause_filehandle_read_watcher {
  my $handle = shift;
  my $kr_handle = $poe_kernel->[KR_HANDLES]->{$handle};
  Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[VEC_RD] );
  $kr_handle->[HND_WATCHERS]->[VEC_RD] = undef;
}

sub _resume_filehandle_read_watcher {
  my $handle = shift;

  # Quietly ignore requests to resume unpaused handles.
  return 1
    if defined $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD];

  $poe_kernel->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD] =
    Gtk::Gdk->input_add( fileno($handle), 'read',
                         \&_select_read_callback, $handle
                       );
}

# Idle callback to dispatch FIFO states.

sub _idle_callback {
  my $self = $poe_kernel;

  _dispatch_one_from_fifo();
  _test_for_idle_poe_kernel();

  # Perpetuate the Gtk idle callback if there's more to do.
  return 1 if @{$self->[KR_STATES]};

  # Otherwise stop it.
  $self->[KR_WATCHER_IDLE] = undef;
  return 0;
}

# Alarm callback to dispatch pending alarm states.

sub _alarm_callback {
  my $self = $poe_kernel;

  _dispatch_due_alarms();
  _test_for_idle_poe_kernel();

  Gtk->timeout_remove( $self->[KR_WATCHER_TIMER] );
  $self->[KR_WATCHER_TIMER] = undef;

  # Register the next timeout if there are alarms left.
  if (@{$self->[KR_ALARMS]}) {
    my $next_time = ($self->[KR_ALARMS]->[0]->[ST_TIME] - time()) * 1000;
    $next_time = 0 if $next_time < 0;
    $self->[KR_WATCHER_TIMER] =
      Gtk->timeout_add( $next_time, \&_alarm_callback );
  }

  # Return false to stop.
  return 0;
}

# Filehandle callback to dispatch selects.

sub _select_read_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;

  _dispatch_ready_selects( $handle, VEC_RD );
  _test_for_idle_poe_kernel();

  # Return false to stop... probably not with this one.
  return 0;
}

sub _select_write_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;

  _dispatch_ready_selects( $handle, VEC_WR );
  _test_for_idle_poe_kernel();

  # Return false to stop... probably not with this one.
  return 0;
}

sub _select_expedite_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;

  _dispatch_ready_selects( $handle, VEC_EX );
  _test_for_idle_poe_kernel();

  # Return false to stop... probably not with this one.
  return 0;
}

#------------------------------------------------------------------------------
# The event loop itself.

sub _start_main_loop {
  Gtk->main;
}

sub _stop_main_loop {
  $poe_main_window->destroy();
  Gtk->main_quit();
}

sub _init_main_loop ($) {
  Gtk->init;

  $poe_main_window = Gtk::Window->new('toplevel');
  die "could not create a main Gk window" unless defined $poe_main_window;

  $poe_main_window->signal_connect( delete_event => \&signal_ui_destroy );
}

1;
