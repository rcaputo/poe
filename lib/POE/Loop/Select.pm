# $Id$

# Select loop personality module for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Select;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Ensure that no other personality module has been loaded.
BEGIN {
  die( "POE can't use its own loop and " . &POE_PERSONALITY_NAME . "\n" )
    if defined &POE_PERSONALITY;
};

use POE::Preprocessor;

# Declare the personality we're using.
sub POE_PERSONALITY      () { PERSONALITY_SELECT      }
sub POE_PERSONALITY_NAME () { PERSONALITY_NAME_SELECT }

#------------------------------------------------------------------------------
# Define signal handlers and the functions that watch them.

sub _signal_handler_generic {
  $POE::Kernel::poe_kernel->_enqueue_state
    ( $POE::Kernel::poe_kernel, $POE::Kernel::poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_signal_handler_generic;
}

sub _signal_handler_pipe {
  $POE::Kernel::poe_kernel->_enqueue_state
    ( $POE::Kernel::poe_kernel, $POE::Kernel::poe_kernel,
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
  $POE::Kernel::poe_kernel->_enqueue_state
    ( $POE::Kernel::poe_kernel, $POE::Kernel::poe_kernel,
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

sub _resume_idle_watcher             ()    { undef }
sub _resume_alarm_watcher            ()    { undef }
sub _pause_alarm_watcher             ()    { undef }
sub _watch_filehandle                ($$$) { undef }
sub _ignore_filehandle               ($$$) { undef }
sub _pause_filehandle_write_watcher  ($)   { undef }
sub _resume_filehandle_write_watcher ($)   { undef }
sub _pause_filehandle_read_watcher   ($)   { undef }
sub _resume_filehandle_read_watcher  ($)   { undef }

#------------------------------------------------------------------------------

sub _init_main_loop  ($) { undef }
sub _start_main_loop ()  { undef }
sub _stop_main_loop  ()  { undef }

1;
