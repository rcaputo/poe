# The data necessary to manage signals, and the accessors to get at
# that data in a sane fashion.

package POE::Resource::Signals;

use vars qw($VERSION);
$VERSION = '1.352'; # NOTE - Should be #.### (three decimal places)

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

use POE::Pipe::OneWay;
use POE::Resource::FileHandles;
use POSIX qw(:sys_wait_h sigprocmask SIG_SETMASK);

### Map watched signal names to the sessions that are watching them
### and the events that must be delivered when they occur.

sub SEV_EVENT   () { 0 }
sub SEV_ARGS    () { 1 }
sub SEV_SESSION () { 2 }

my %kr_signals;
#  ( $signal_name =>
#    { $session_id =>
#     [ $event_name,    SEV_EVENT
#       $event_args,    SEV_ARGS
#       $session_ref,   SEV_SESSION
#     ],
#      ...,
#    },
#    ...,
#  );

my %kr_sessions_to_signals;
#  ( $session_id =>
#    { $signal_name =>
#      [ $event_name,   SEV_EVENT
#        $event_args,   SEV_ARGS
#        $session_ref,  SEV_SESSION
#      ],
#      ...,
#    },
#    ...,
#  );

my %kr_pids_to_events;
# { $pid =>
#   { $session_id =>
#     [ $blessed_session,   # PID_SESSION
#       $event_name,        # PID_EVENT
#       $args,              # PID_ARGS
#     ]
#   }
# }

my %kr_sessions_to_pids;
# { $session_id => { $pid => 1 } }

sub PID_SESSION () { 0 }
sub PID_EVENT   () { 1 }
sub PID_ARGS    () { 2 }

sub _data_sig_relocate_kernel_id {
  my ($self, $old_id, $new_id) = @_;

  while (my ($signal, $sig_rec) = each %kr_signals) {
    next unless exists $sig_rec->{$old_id};
    $sig_rec->{$new_id} = delete $sig_rec->{$old_id};
  }

  $kr_sessions_to_signals{$new_id} = delete $kr_sessions_to_signals{$old_id}
    if exists $kr_sessions_to_signals{$old_id};

  while (my ($pid, $pid_rec) = each %kr_pids_to_events) {
    next unless exists $pid_rec->{$old_id};
    $pid_rec->{$new_id} = delete $pid_rec->{$old_id};
  }

  $kr_sessions_to_pids{$new_id} = delete $kr_sessions_to_pids{$old_id}
    if exists $kr_sessions_to_pids{$old_id};
}

# Bookkeeping per dispatched signal.

# TODO - Why not lexicals?
use vars (
 '@kr_signaled_sessions',            # The sessions touched by a signal.
 '$kr_signal_total_handled',         # How many sessions handled a signal.
 '$kr_signal_type',                  # The type of signal being dispatched.
);

#my @kr_signaled_sessions;           # The sessions touched by a signal.
#my $kr_signal_total_handled;        # How many sessions handled a signal.
#my $kr_signal_type;                 # The type of signal being dispatched.

# A flag to tell whether we're currently polling for signals.
# Under USE_SIGCHLD, determines whether a SIGCHLD polling event has
# already been queued.
my $polling_for_signals = 0;

# A flag determining whether there are child processes.
use constant BASE_SIGNAL_COUNT => (
  exists($INC{'Apache.pm'}) ? 0 : ( USE_SIGCHLD ? 0 : 1 )
);

my $kr_has_child_procs = BASE_SIGNAL_COUNT;

# A list of special signal types.  Signals that aren't listed here are
# benign (they do not kill sessions at all).  "Terminal" signals are
# the ones that UNIX defaults to killing processes with.  Thus STOP is
# not terminal.

sub SIGTYPE_BENIGN      () { 0x00 }
sub SIGTYPE_TERMINAL    () { 0x01 }
sub SIGTYPE_NONMASKABLE () { 0x02 }

my %_signal_types = (
  QUIT => SIGTYPE_TERMINAL,
  INT  => SIGTYPE_TERMINAL,
  KILL => SIGTYPE_TERMINAL,
  TERM => SIGTYPE_TERMINAL,
  HUP  => SIGTYPE_TERMINAL,
  IDLE => SIGTYPE_TERMINAL,
  DIE  => SIGTYPE_TERMINAL,
  ZOMBIE    => SIGTYPE_NONMASKABLE,
  UIDESTROY => SIGTYPE_NONMASKABLE,
);

# Build a list of useful, real signals.  Nonexistent signals, and ones
# which are globally unhandled, usually cause segmentation faults if
# perl was poorly configured.  Some signals aren't available in some
# environments.

my %_safe_signals;

sub _data_sig_initialize {
  my $self = shift;

  $self->_data_sig_reset_procs;

  $poe_kernel->[KR_SIGNALS] = \%kr_signals;
  $poe_kernel->[KR_PIDS]    = \%kr_pids_to_events;

  # In case we're called multiple times.
  unless (keys %_safe_signals) {
    foreach my $signal (keys %SIG) {

      # Nonexistent signals, and ones which are globally unhandled.
      next if (
        $signal =~ /^
          ( NUM\d+
          |__[A-Z0-9]+__
          |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE
          |RTMIN|RTMAX|SETS
          |SEGV
          |
          )
        $/x
      );

      # Windows doesn't have a SIGBUS, but the debugger causes SIGBUS
      # to be entered into %SIG.  It's fatal to register its handler.
      next if $signal eq 'BUS' and RUNNING_IN_HELL;

      # Apache uses SIGCHLD and/or SIGCLD itself, so we can't.
      next if $signal =~ /^CH?LD$/ and exists $INC{'Apache.pm'};

      $_safe_signals{$signal} = 1;
    }

    # Reset some important signal handlers.  The rest remain
    # untouched.

    $self->loop_ignore_signal("CHLD") if exists $SIG{CHLD};
    $self->loop_ignore_signal("CLD")  if exists $SIG{CLD};
    $self->loop_ignore_signal("PIPE") if exists $SIG{PIPE};

    $self->_data_sig_pipe_build if USE_SIGNAL_PIPE;
  }
}

sub _data_sig_has_forked {
  my( $self ) = @_;
  $self->_data_sig_reset_procs;
  if( USE_SIGNAL_PIPE ) {
    $self->_data_sig_mask_all;
    $self->_data_sig_pipe_finalize;
    $self->_data_sig_pipe_build;
    $self->_data_sig_unmask_all;
  }
}

sub _data_sig_reset_procs {
  my $self = shift;
  # Initialize this to a true value so our waitpid() loop can run at
  # least once.  Starts false when running in an Apache handler so our
  # SIGCHLD hijinks don't interfere with the web server.
  $self->_data_sig_cease_polling();
  $kr_has_child_procs = BASE_SIGNAL_COUNT;
}


### Return signals that are safe to manipulate.

sub _data_sig_get_safe_signals {
  return keys %_safe_signals;
}

### End-run leak checking.
our $finalizing;

sub _data_sig_finalize {
  my( $self ) = @_;
  my $finalized_ok = 1;
  # tell _data_sig_pipe_send to ignore CHLD that waitpid might provoke
  local $finalizing = 1;

  $self->_data_sig_pipe_finalize;

  while (my ($sig, $sig_rec) = each(%kr_signals)) {
    $finalized_ok = 0;
    _warn "!!! Leaked signal $sig\n";
    while (my ($sid, $ses_rec) = each(%{$kr_signals{$sig}})) {
      my ($event, $args, $session) = @$ses_rec;
      _warn "!!!\t$sid = $session -> $event (@$args)\n";
    }
  }

  while (my ($sid, $ses_rec) = each(%kr_sessions_to_signals)) {
    $finalized_ok = 0;
    _warn "!!! Leaked signal cross-reference: $sid\n";
    while (my ($sig, $sig_rec) = each(%{$kr_signals{$sid}})) {
      my ($event, $args) = @$sig_rec;
      _warn "!!!\t$sig = $event (@$args)\n";
    }
  }

  while (my ($sid, $pid_rec) = each(%kr_sessions_to_pids)) {
    $finalized_ok = 0;
    my @pids = keys %$pid_rec;
    _warn "!!! Leaked session to PID map: $sid -> (@pids)\n";
  }

  while (my ($pid, $ses_rec) = each(%kr_pids_to_events)) {
    $finalized_ok = 0;
    _warn "!!! Leaked PID to event map: $pid\n";
    while (my ($sid, $ev_rec, $ses) = each %$ses_rec) {
      _warn "!!!\t$ses -> $ev_rec->[PID_EVENT] (@{$ev_rec->[PID_ARGS]})\n";
    }
  }

  %_safe_signals = ();

  unless (RUNNING_IN_HELL) {
    local $!;
    local $?;

    my $leaked_children = 0;

    PROCESS: until ((my $pid = waitpid( -1, WNOHANG )) == -1) {
      $finalized_ok = 0;
      $leaked_children++;

      if ($pid == 0) {
        _warn(
          "!!! At least one child process is still running " .
          "when POE::Kernel->run() is ready to return.\n"
        );
        last PROCESS;
      }

      _warn(
        "!!! Stopped child process (PID $pid) reaped " .
          "when POE::Kernel->run() is ready to return.\n"
      );
    }

    if ($leaked_children) {
      _warn("!!! Be sure to use sig_child() to reap child processes.\n");
      _warn("!!! In extreme cases, failure to reap child processes has\n");
      _warn("!!! resulted in a slow 'fork bomb' that has halted systems.\n");
    }
  }

  return $finalized_ok;
}

### Add a signal to a session.

sub _data_sig_add {
  my ($self, $session, $signal, $event, $args) = @_;

  my $sid = $session->ID;
  $kr_sessions_to_signals{$sid}->{$signal} = [ $event, $args || [], $session ];
  $self->_data_sig_signal_watch($sid, $signal);
  $kr_signals{$signal}->{$sid} = [ $event, $args || [], $session ];
}

sub _data_sig_signal_watch {
  my ($self, $sid, $signal) = @_;

  # TODO - $sid not used?

  # First session to watch the signal.
  # Ask the event loop to watch the signal.
  if (
    !exists($kr_signals{$signal}) and
    exists($_safe_signals{$signal}) and
    ($signal ne "CHLD" or !scalar(keys %kr_sessions_to_pids))
  ) {
    $self->loop_watch_signal($signal);
  }
}

sub _data_sig_signal_ignore {
  my ($self, $sid, $signal) = @_;

  # TODO - $sid not used?

  if (
    !exists($kr_signals{$signal}) and
    exists($_safe_signals{$signal}) and
    ($signal ne "CHLD" or !scalar(keys %kr_sessions_to_pids))
  ) {
    $self->loop_ignore_signal($signal);
  }
}

### Remove a signal from a session.

sub _data_sig_remove {
  my ($self, $sid, $signal) = @_;

  delete $kr_sessions_to_signals{$sid}->{$signal};
  delete $kr_sessions_to_signals{$sid}
    unless keys(%{$kr_sessions_to_signals{$sid}});

  delete $kr_signals{$signal}->{$sid};

  # Last watcher for that signal.  Stop watching it internally.
  unless (keys %{$kr_signals{$signal}}) {
    delete $kr_signals{$signal};
    $self->_data_sig_signal_ignore($sid, $signal);
  }
}

### Clear all the signals from a session.

# XXX - It's ok to clear signals from a session that doesn't exist.
# Usually it means that the signals are being cleared, but it might
# mean that the session really doesn't exist.  Should we care?

sub _data_sig_clear_session {
  my ($self, $sid) = @_;

  if (exists $kr_sessions_to_signals{$sid}) { # avoid autoviv
    foreach (keys %{$kr_sessions_to_signals{$sid}}) {
      $self->_data_sig_remove($sid, $_);
    }
  }

  if (exists $kr_sessions_to_pids{$sid}) { # avoid autoviv
    foreach (keys %{$kr_sessions_to_pids{$sid}}) {
      $self->_data_sig_pid_ignore($sid, $_);
    }
  }
}

### Watch and ignore PIDs.

sub _data_sig_pid_watch {
  my ($self, $session, $pid, $event, $args) = @_;

  my $sid = $session->ID;

  $kr_pids_to_events{$pid}{$sid} = [
    $session, # PID_SESSION
    $event,   # PID_EVENT
    $args,    # PID_ARGS
  ];

  $self->_data_sig_signal_watch($sid, "CHLD");

  $kr_sessions_to_pids{$sid}{$pid} = 1;
  $self->_data_ses_refcount_inc($sid);

  # Assume there's a child process.  This will be corrected on the
  # next polling interval.
  $kr_has_child_procs++ unless USE_SIGCHLD;
}

sub _data_sig_pid_ignore {
  my ($self, $sid, $pid) = @_;

  # Remove PID to event mapping.

  delete $kr_pids_to_events{$pid}{$sid};
  delete $kr_pids_to_events{$pid} unless (
    keys %{$kr_pids_to_events{$pid}}
  );

  # Remove session to PID mapping.

  delete $kr_sessions_to_pids{$sid}{$pid};
  unless (keys %{$kr_sessions_to_pids{$sid}}) {
    delete $kr_sessions_to_pids{$sid};
    $self->_data_sig_signal_ignore($sid, "CHLD");
  }

  $self->_data_ses_refcount_dec($sid);
}

sub _data_sig_session_awaits_pids {
  my ($self, $sid) = @_;

  # There must be child processes or pending signals.
  # Watching PIDs doesn't matter if there are none to be reaped.
  return 0 unless $kr_has_child_procs or $self->_data_sig_pipe_has_signals();

  # This session is watching at least one PID with sig_child().
  # TODO - Watching a non-existent PID is legal but ill-advised.
  return 1 if exists $kr_sessions_to_pids{$sid};

  # Is the session waiting for a blanket sig(CHLD)?
  return(
    (exists $kr_sessions_to_signals{$sid}) &&
    (exists $kr_sessions_to_signals{$sid}{CHLD})
  );
}

sub _data_sig_pids_is_ses_watching {
  my ($self, $sid, $pid) = @_;
  return(
    exists($kr_sessions_to_pids{$sid}) &&
    exists($kr_sessions_to_pids{$sid}{$pid})
  );
}

### Return a signal's type, or SIGTYPE_BENIGN if it's not special.

sub _data_sig_type {
  my ($self, $signal) = @_;
  return $_signal_types{$signal} || SIGTYPE_BENIGN;
}

### Flag a signal as being handled by some session.

sub _data_sig_handled {
  my $self = shift;
  $kr_signal_total_handled++;
}

### Clear the structures associated with a signal's "handled" status.

sub _data_sig_reset_handled {
  my ($self, $signal) = @_;
  undef $kr_signal_total_handled;
  $kr_signal_type = $self->_data_sig_type($signal);
  undef @kr_signaled_sessions;
}

### Is the signal explicitly watched?

sub _data_sig_explicitly_watched {
  my ($self, $signal) = @_;
  return exists $kr_signals{$signal};
}

### Return the signals watched by a session and the events they
### generate.  TODO Used mainly for testing, but may also be useful
### for introspection.

sub _data_sig_watched_by_session {
  my ($self, $sid) = @_;
  return unless exists $kr_sessions_to_signals{$sid};
  return %{$kr_sessions_to_signals{$sid}};
}

### Which sessions are watching a signal?

sub _data_sig_watchers {
  my ($self, $signal) = @_;
  return %{$kr_signals{$signal}};
}

### Return the current signal's handled status.
### TODO Used for testing.

sub _data_sig_handled_status {
  return(
    $kr_signal_total_handled,
    $kr_signal_type,
    \@kr_signaled_sessions,
  );
}

### Determine if a given session is watching a signal.  This uses a
### two-step exists so that the longer one does not autovivify keys in
### the shorter one.

sub _data_sig_is_watched_by_session {
  my ($self, $signal, $sid) = @_;
  return(
    exists($kr_signals{$signal}) &&
    exists($kr_signals{$signal}->{$sid})
  );
}

### Destroy sessions touched by a nonmaskable signal or by an
### unhandled terminal signal.  Check for garbage-collection on
### sessions which aren't to be terminated.

sub _data_sig_free_terminated_sessions {
  my $self = shift;

  if (
    ($kr_signal_type & SIGTYPE_NONMASKABLE) or
    ($kr_signal_type & SIGTYPE_TERMINAL and !$kr_signal_total_handled)
  ) {
    foreach my $dead_session (@kr_signaled_sessions) {
      next unless $self->_data_ses_exists($dead_session->ID);

      if (TRACE_SIGNALS) {
        _warn(
          "<sg> stopping signaled session ",
          $self->_data_alias_loggable($dead_session->ID)
        );
      }

      $self->_data_ses_stop($dead_session->ID);
    }
  }

  # Erase @kr_signaled_sessions, or they will leak until the next
  # signal.
  @kr_signaled_sessions = ();
}

### A signal has touched a session.  Record this fact for later
### destruction tests.

sub _data_sig_touched_session {
  my ($self, $session) = @_;
  push @kr_signaled_sessions, $session;
}

# only used under !USE_SIGCHLD
sub _data_sig_begin_polling {
  my ($self, $signal) = @_;

  return if $polling_for_signals;
  $polling_for_signals = 1;

  $self->_data_sig_enqueue_poll_event($signal);
  $self->_idle_queue_grow();
}

# only used under !USE_SIGCHLD
sub _data_sig_cease_polling {
  $polling_for_signals = 0;
}

sub _data_sig_enqueue_poll_event {
  my ($self, $signal) = @_;

  if ( USE_SIGCHLD ) {
    return if $polling_for_signals;
    $polling_for_signals = 1;

    $self->_data_ev_enqueue(
      $self, $self, EN_SCPOLL, ET_SCPOLL, [ $signal ],
      __FILE__, __LINE__, undef, time(),
    );
  } else {
    return if $self->_data_ses_count() < 1;
    return unless $polling_for_signals;

    $self->_data_ev_enqueue(
      $self, $self, EN_SCPOLL, ET_SCPOLL, [ $signal ],
      __FILE__, __LINE__, undef, time() + POE::Kernel::CHILD_POLLING_INTERVAL(),
    );
  }
}

sub _data_sig_handle_poll_event {
  my ($self, $signal) = @_;

  if ( USE_SIGCHLD ) {
    $polling_for_signals = undef;
  }

  if (TRACE_SIGNALS) {
    _warn(
      "<sg> POE::Kernel is polling for signals at " . time() .
      (USE_SIGCHLD ? " due to SIGCHLD" : "")
    );
  }

  $self->_data_sig_reap_pids();

  # The poll loop is over.  Resume slowly polling for signals.

  if (USE_SIGCHLD) {
    if (TRACE_SIGNALS) {
      _warn("<sg> POE::Kernel has reset the SIG$signal handler");
    }
    # Per https://rt.cpan.org/Ticket/Display.html?id=45109 setting the
    # signal handler must be done after reaping the outstanding child
    # processes, at least on SysV systems like HP-UX.
    $SIG{$signal} = \&_loop_signal_handler_chld;
  }
  else {
    # The poll loop is over.  Resume slowly polling for signals.

    if ($polling_for_signals) {
      if (TRACE_SIGNALS) {
        _warn("<sg> POE::Kernel will poll again after a delay");
      }
      $self->_data_sig_enqueue_poll_event($signal);
    }
    else {
      if (TRACE_SIGNALS) {
        _warn("<sg> POE::Kernel SIGCHLD poll loop paused");
      }
      $self->_idle_queue_shrink();
    }
  }
}

sub _data_sig_reap_pids {
  my $self = shift();

  # Reap children for as long as waitpid(2) says something
  # interesting has happened.
  # TODO This has a possibility of an infinite loop, but so far it
  # hasn't hasn't happened.

  my $pid;
  while ($pid = waitpid(-1, WNOHANG)) {
    # waitpid(2) returned a process ID.  Emit an appropriate SIGCHLD
    # event and loop around again.

    if (($pid > 0) or (RUNNING_IN_HELL and $pid < -1)) {
      if (RUNNING_IN_HELL or WIFEXITED($?) or WIFSIGNALED($?)) {

        if (TRACE_SIGNALS) {
          _warn("<sg> POE::Kernel detected SIGCHLD (pid=$pid; exit=$?)");
        }

        # Check for explicit SIGCHLD watchers, and enqueue explicit
        # events for them.

        if (exists $kr_pids_to_events{$pid}) {
          my @sessions_to_clear;
          while (my ($sid, $ses_rec) = each %{$kr_pids_to_events{$pid}}) {
            $self->_data_ev_enqueue(
              $ses_rec->[PID_SESSION], $self, $ses_rec->[PID_EVENT], ET_SIGCLD,
              [ 'CHLD', $pid, $?, @{$ses_rec->[PID_ARGS]} ],
              __FILE__, __LINE__, undef, time(),
            );
            push @sessions_to_clear, $sid;
          }
          $self->_data_sig_pid_ignore($_, $pid) foreach @sessions_to_clear;
        }

        # Kick off a SIGCHLD cascade.
        $self->_data_ev_enqueue(
          $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'CHLD', $pid, $? ],
          __FILE__, __LINE__, undef, time(),
        );
      }
      elsif (TRACE_SIGNALS) {
        _warn("<sg> POE::Kernel detected strange exit (pid=$pid; exit=$?");
      }

      if (TRACE_SIGNALS) {
        _warn("<sg> POE::Kernel will poll again immediately");
      }

      next;
    }

    # The only other negative value waitpid(2) should return is -1.
    # This is highly unlikely, but it's necessary to catch
    # portability problems.
    #
    # TODO - Find a way to test this.

    _trap "internal consistency error: waitpid returned $pid" if $pid != -1;

    # If the error is an interrupted syscall, poll again right away.

    if ($! == EINTR) {
      if (TRACE_SIGNALS) {
        _warn(
          "<sg> POE::Kernel's waitpid(2) was interrupted.\n",
          "POE::Kernel will poll again immediately.\n"
        );
      }
      next;
    }

    # No child processes exist.  TODO This is different than
    # children being present but running.  Maybe this condition
    # could halt polling entirely, and some UNIVERSAL::fork wrapper
    # could restart polling when processes are forked.

    if ($! == ECHILD) {
      if (TRACE_SIGNALS) {
        _warn("<sg> POE::Kernel has no child processes");
      }
      last;
    }

    # Some other error occurred.

    if (TRACE_SIGNALS) {
      _warn("<sg> POE::Kernel's waitpid(2) got error: $!");
    }
    last;
  }

  # Remember whether there are more processes to reap.

  $kr_has_child_procs = !$pid;
}

# Are there child processes worth waiting for?
# We don't really care if we're not polling for signals.

sub _data_sig_kernel_awaits_pids {
  my $self = shift();

  return 0 if !USE_SIGCHLD and !$polling_for_signals;

  # There must be child processes or pending signals.
  return 0 unless $kr_has_child_procs or $self->_data_sig_pipe_has_signals();

  # At least one session is watching an explicit PID.
  # TODO - Watching a non-existent PID is legal but ill-advised.
  return 1 if scalar keys %kr_pids_to_events;

  # Is the session waiting for a blanket sig(CHLD)?
  return exists $kr_signals{CHLD};
}

######################
## Safe signals, the final solution:
## Semantically, signal handlers and the main loop are in different threads.
## To avoid all possible deadlock and race conditions once and for all we
## implement them as shared-nothing threads.
##
## The signal handlers are split in 2 :
##  - a top handler, which sends the signal number over a one-way pipe.
##  - a bottom handler, which is called when this number is received in the
##  main loop.
## The top handler will send a packet of PID and number.  We need the PID
## because of the race condition with signals in perl; signals meant for the
## parent end up in both the parent and child.  So we check the PID to make
## sure it was intended for the child.  We use 'ii' (2 ints, aka 8 bytes)
## and not 'iC' (int+byte, aka 5 bytes) because we want a small factor of
## the buffer size in the hopes of never getting a short read.  Ever.

use vars qw( $signal_pipe_read_fd );
my( $signal_pipe_write, $signal_pipe_read, $signal_pipe_pid, 
    $signal_pipe_len, $signal_pipe_remainder, $signal_pipe_format, 
    $signal_mask_none, $signal_mask_all, %SIG2NUM, %NUM2SIG );


sub _data_sig_pipe_has_signals {
  my $self = shift();
  return unless $signal_pipe_read;
  my $vec = '';
  vec($vec, fileno($signal_pipe_read), 1) = 1;

  # Ambiguous call resolved as CORE::select(), qualify as such or use &
  return(CORE::select($vec, undef, undef, 0) > 0);
}


sub _data_sig_pipe_build {
  my( $self ) = @_;
  return unless USE_SIGNAL_PIPE;
  my $fake = 128;

  $signal_pipe_remainder = '';
  $signal_pipe_format = "ii";   # pid_t is int on Linux
  $signal_pipe_len = length pack $signal_pipe_format, 0, 0;
  
  unless( %SIG2NUM ) {
    foreach my $sig ( keys %_safe_signals ) {
      my $n = eval "POSIX::SIG$sig()";
      # warn $@;
      if( $@ ) {    # AKA : RUNNING_IN_HELL
          # The number used is less important then the fact that it has
          # a unique number assigned to it
          $n = $fake++;
          _trap "<sg> SIG$sig not defined and $n > 255" if $n > 255;
      }
      else {
          # paranoid check
          _trap "<sg> SIG$sig is out of range ($n)" if $n > 127;
      }
      $SIG2NUM{ $sig } = $n;
      $NUM2SIG{ $n } = $sig;
    }
    # warn join "\n", map { "$_: $SIG2NUM{$_}" } sort keys %SIG2NUM;
    # we need CLD to be named CHLD
    $SIG2NUM{ CLD } = $SIG2NUM{ CHLD };
    $NUM2SIG{ $SIG2NUM{ CHLD } } = 'CHLD';
    $NUM2SIG{ $SIG2NUM{ CLD } } = 'CHLD' if $SIG2NUM{ CLD };
    # warn join "\n", map { "$_: $_safe_signals{$_}" } sort keys %_safe_signals;
  }

  # Associate the pipe with this PID
  $signal_pipe_pid = $$;

  # Mess with the signal mask
  $self->_data_sig_mask_all;

  # Open the signal pipe
  if (RUNNING_IN_HELL) {
    ( $signal_pipe_read, $signal_pipe_write ) = POE::Pipe::OneWay->new('inet');
  }
  else {
    ( $signal_pipe_read, $signal_pipe_write ) = POE::Pipe::OneWay->new('pipe');
  }
  _trap "<sg> Error " . ($!+0) . " trying to create the signal pipe: $!" unless $signal_pipe_write;

  # Allows Resource::FileHandles to by-pass the queue
  $signal_pipe_read_fd = fileno $signal_pipe_read;
  if( TRACE_SIGNALS ) {
    _warn "<sg> signal_pipe_write=$signal_pipe_write";
    _warn "<sg> signal_pipe_read=$signal_pipe_read";
    _warn "<sg> signal_pipe_read_fd=$signal_pipe_read_fd";
  }

  # Add to the select list
  $self->_data_handle_condition( $signal_pipe_read );
  $self->loop_watch_filehandle( $signal_pipe_read, MODE_RD );
  $self->_data_sig_unmask_all;
}

sub _data_sig_mask_build {
  return if RUNNING_IN_HELL;
  $signal_mask_none  = POSIX::SigSet->new();
  $signal_mask_none->emptyset();
  $signal_mask_all  = POSIX::SigSet->new();
  $signal_mask_all->fillset();
}

### Mask all signals
sub _data_sig_mask_all {
  return if RUNNING_IN_HELL;
  my $self = $poe_kernel;
  unless( $signal_mask_all ) {
    $self->_data_sig_mask_build;
  }
  my $mask_temp = POSIX::SigSet->new();
  sigprocmask( SIG_SETMASK, $signal_mask_all, $mask_temp )
            or _trap "<sg> Unable to mask all signals: $!";
}

### Unmask all signals
sub _data_sig_unmask_all {
  return if RUNNING_IN_HELL;
  my $self = $poe_kernel;
  unless( $signal_mask_none ) {
    $self->_data_sig_mask_build;
  }
  my $mask_temp = POSIX::SigSet->new();
  sigprocmask( SIG_SETMASK, $signal_mask_none, $mask_temp )
        or _trap "<sg> Unable to unmask all signals: $!";
}



sub _data_sig_pipe_finalize {
  my( $self ) = @_;
  if( $signal_pipe_read ) {
    $self->loop_ignore_filehandle( $signal_pipe_read, MODE_RD );
    close $signal_pipe_read; undef $signal_pipe_read;
  }
  if( $signal_pipe_write ) {
    close $signal_pipe_write; undef $signal_pipe_write;
  }
  # Don't send anything more!
  undef( $signal_pipe_pid );
}

### Send a signal "message" to the main thread
### Called from the top signal handlers
sub _data_sig_pipe_send {
  my $n = $SIG2NUM{ $_[1] };
  if( ASSERT_DATA ) {
    _trap "<sg> Unknown signal $_[1]" unless defined $n;
  }
  if( TRACE_SIGNALS ) {
    _warn "<sg> Caught SIG$_[1] ($n)";
  }
  
  return if $finalizing;
  
  if( not defined $signal_pipe_pid ) {
    _trap "<sg> _data_sig_pipe_send called before signal pipe was initialized.";
  }
  # ugh- has_forked() can't be called fast enough.  This warning might
  # show up before it is called.  Should we just detect forking and do it
  # for the user?  Probably not...
  if( $$ != $signal_pipe_pid ) {
    _warn "<sg> Kernel now running in a different process (is=$$ was=$signal_pipe_pid ).  You must call call \$poe_kernel->has_forked in the child process.";
  }

  my $count = _data_sig_pipe_syswrite( pack( $signal_pipe_format, $$, $n ) );
  if( ASSERT_DATA ) {
    if( $count != $signal_pipe_len ) {
      _trap "<sg> Wrote more than one byte (count=$count)";
    }
  }
}

### write one signal number to the pipe
sub _data_sig_pipe_syswrite {
  my( $data ) = @_;
  my $count = syswrite( $signal_pipe_write, $data );
  if( defined $count and $count > 0 ) {
    $! = 0;
    if( TRACE_SIGNALS ) {
      _warn "<sg> Wrote $count byte(s) to signal pipe";
    }

    return $count;
  }

  # if we got here, something bad happened
  if( $! == EAGAIN or $! == EWOULDBLOCK ) {
    _trap "<sg> Excessive signals detected; signal pipe full: $!";
  }
  _trap "<sg> Error " . ($!+0) . " writing to signal pipe: $!";
}

### Read all signal numbers.
### Call the related bottom handler.  That is, inside the kernel loop.
sub _data_sig_pipe_read {
  my( $self, $fileno, $mode ) = @_;
  if( ASSERT_DATA ) {
    _trap "Illegal mode=$mode on fileno=$fileno" unless
                                    $fileno == $signal_pipe_read_fd
                                and $mode eq MODE_RD;
  }
  my $data = $self->_data_sig_pipe_sysread();
  return unless defined $data;

  my $count = length $data;
  if( TRACE_SIGNALS ) {
    _warn "<sg> Read $count bytes from signal pipe";
  }
  return unless $count;

  $data = $signal_pipe_remainder . $data;
  $signal_pipe_remainder = '';

  $count = length $data;
  for(my $q=0; $q< $count; $q+=$signal_pipe_len ) {
    if( $q + $signal_pipe_len > $count ) {
        $signal_pipe_remainder = substr( $data, $q );
        last;
    }
    my($pid, $n) = unpack $signal_pipe_format, substr( $data, $q, $signal_pipe_len );
    next if $pid != $$; # ignore a 'packet' meant for our parent
    next if $n == 0;
    if( ASSERT_DATA ) {
      _trap "Unknown signal number $n" unless $NUM2SIG{ $n };
    }
    my $sig = $NUM2SIG{ $n };
    if( $sig eq 'CHLD' ) {
      _loop_signal_handler_chld_bottom( $sig );
    }
    elsif( $sig eq 'PIPE' ) {
      _loop_signal_handler_pipe_bottom( $sig );
    }
    else {
      _loop_signal_handler_generic_bottom( $sig );
    }
  }
}

### Read all signal numbers from the pipe
sub _data_sig_pipe_sysread {
  my $data = '';
  # To avoid flooding the queue, we don't read the entire pipe at once
  # PG- Mind you, I doubt signal flooding is ever going to be much of
  # a problem, is it?
  my $result = sysread( $signal_pipe_read, $data, 256*$signal_pipe_len ); # XXX
  if( defined $result ) {
    $! = 0;
    return $data;
  }
  # Nonfatal sysread() error.  Return an empty list.
  return '' if $! == EAGAIN or $! == EWOULDBLOCK;

  if( ASSERT_DATA ) {
    _trap "<sg> Error " . ($!+0) . " reading from signal pipe: $!";
  }
  elsif( TRACE_SIGNALS ) {
    _warn "<sg> Error " . ($!+0) . " reading from signal pipe: $!";
  }
  return;
}


1;

__END__

=head1 NAME

POE::Resource::Signals - internal signal manager for POE::Kernel

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE::Resource::Signals is a mix-in class for POE::Kernel.  It provides
the features needed to manage signals.  It is used internally by
POE::Kernel, so it has no public interface.

=head1 SEE ALSO

See L<POE::Kernel/Signals> for a deeper discussion about POE's signal
handling.

See L<POE::Kernel/Signal Watcher Methods> for POE's public signals
API.

See L<POE::Kernel/Resources> for for public information about POE
resources.

See L<POE::Resource> for general discussion about resources and the
classes that manage them.

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
