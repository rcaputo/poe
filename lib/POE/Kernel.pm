# $Id$

package POE::Kernel;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use POE::Queue::Array;
use POSIX qw(errno_h fcntl_h sys_wait_h);
use Carp qw(carp croak confess cluck);
use Sys::Hostname qw(hostname);

# People expect these to be lexical.

use vars qw($poe_kernel $poe_main_window);

#------------------------------------------------------------------------------
# A cheezy exporter to avoid using Exporter.

sub import {
  my $package = caller();
  no strict 'refs';
  *{ $package . '::poe_kernel'      } = \$poe_kernel;
  *{ $package . '::poe_main_window' } = \$poe_main_window;
}

#------------------------------------------------------------------------------
# Perform some optional setup.

sub RUNNING_IN_HELL () { $^O eq 'MSWin32' }

BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';

  # POE runs better with Time::HiRes, but it also runs without it.
  eval {
    require Time::HiRes;
    Time::HiRes->import qw(time sleep);
  };

  # http://support.microsoft.com/support/kb/articles/Q150/5/37.asp
  # defines EINPROGRESS as 10035.  We provide it here because some
  # Win32 users report POSIX::EINPROGRESS is not vendor-supported.
  if (RUNNING_IN_HELL) {
    eval '*EINPROGRESS = sub { 10036 };';  # not used here?
    eval '*EWOULDBLOCK = sub { 10035 };';
    eval '*F_GETFL     = sub {     0 };';
    eval '*F_SETFL     = sub {     0 };';
  }
}

#==============================================================================
# Globals, or at least package-scoped things.  Data structurse were
# moved into lexicals in 0.1201.

# A flag determining whether there are child processes.  Starts true
# so our waitpid() loop can run at least once.
my $kr_child_procs = 1;

# A reference to the currently active session.  Used throughout the
# functions that act on the current session.
my $kr_active_session;

# The Kernel's master queue.
my $kr_queue;

# Filehandle vector sub-fields.  These are used in a few places.
sub VEC_RD () { 0 }
sub VEC_WR () { 1 }
sub VEC_EX () { 2 }

#------------------------------------------------------------------------------
# Kernel structure.  This is the root of a large data tree.  Dumping
# $poe_kernel with Data::Dumper or something will show most of the
# data that POE keeps track of.  The exceptions to this are private
# storage in some of the leaf objects, such as POE::Wheel.  All its
# members are described in detail further on.

sub KR_SESSIONS       () {  0 } # [ \%kr_sessions,
sub KR_FILENOS        () {  1 } #   \%kr_filenos,
sub KR_SIGNALS        () {  2 } #   \%kr_signals,
sub KR_ALIASES        () {  3 } #   \%kr_aliases,
sub KR_ACTIVE_SESSION () {  4 } #   \$kr_active_session,
sub KR_QUEUE          () {  5 } #   \$kr_queue,
sub KR_ID             () {  6 } #   $unique_kernel_id,
sub KR_SESSION_IDS    () {  7 } #   \%kr_session_ids,
sub KR_SID_SEQ        () {  8 } #   \$kr_sid_seq,
sub KR_EXTRA_REFS     () {  9 } #   \$kr_extra_refs,
sub KR_SIZE           () { 10 } #   XXX UNUSED ???
                                # ]

# This flag indicates that POE::Kernel's run() method was called.
# It's used to warn about forgetting $poe_kernel->run().

sub KR_RUN_CALLED  () { 0x01 }  # $kernel->run() called
sub KR_RUN_SESSION () { 0x02 }  # sessions created
sub KR_RUN_DONE    () { 0x04 }  # run returned
my $kr_run_warning = 0;

#------------------------------------------------------------------------------
# Events themselves.

sub EV_SESSION    () { 0 }  # [ $destination_session,
sub EV_SOURCE     () { 1 }  #   $sender_session,
sub EV_NAME       () { 2 }  #   $event_name,
sub EV_TYPE       () { 3 }  #   $event_type,
sub EV_ARGS       () { 4 }  #   \@event_parameters_arg0_etc,
                            #
                            #   (These fields go towards the end
                            #   because they are optional in some
                            #   cases.  TODO: Is this still true?)
                            #
sub EV_OWNER_FILE () { 5 }  #   $caller_filename_where_enqueued,
sub EV_OWNER_LINE () { 6 }  #   $caller_line_where_enqueued,
                            # ]

sub EV_TIME       () { 7 }  # Maintained by POE::Queue
sub EV_SEQ        () { 8 }  # Maintained by POE::Queue

# These are the names of POE's internal events.  They're in constants
# so we don't mistype them again.

sub EN_CHILD  () { '_child'           }
sub EN_GC     () { '_garbage_collect' }
sub EN_PARENT () { '_parent'          }
sub EN_SCPOLL () { '_sigchld_poll'    }
sub EN_SIGNAL () { '_signal'          }
sub EN_START  () { '_start'           }
sub EN_STOP   () { '_stop'            }

# These are POE's event classes (types).  They often shadow the event
# names themselves, but they can encompass a large group of events.
# For example, ET_ALARM describes anything enqueued as by an alarm
# call.  Types are preferred over names because bitmask tests are
# faster than sring equality tests.

sub ET_USER   () { 0x0001 }  # User events (posted ones).
sub ET_CALL   () { 0x0002 }  # User events that weren't enqueued. (XXX UNUSED?)
sub ET_START  () { 0x0004 }  # _start
sub ET_STOP   () { 0x0008 }  # _stop
sub ET_SIGNAL () { 0x0010 }  # _signal
sub ET_GC     () { 0x0020 }  # _garbage_collect
sub ET_PARENT () { 0x0040 }  # _parent
sub ET_CHILD  () { 0x0080 }  # _child
sub ET_SCPOLL () { 0x0100 }  # _sigchild_poll
sub ET_ALARM  () { 0x0200 }  # Alarm events.
sub ET_SELECT () { 0x0400 }  # File activity events.

# Temporary signal subtypes, used during signal dispatch semantics
# deprecation and reformation.

sub ET_SIGNAL_EXPLICIT   () { 0x0800 }  # Explicitly requested signal.
sub ET_SIGNAL_COMPATIBLE () { 0x1000 }  # Backward-compatible semantics.

# A hash of reserved names.  It's used to test whether someone is
# trying to use an internal event directoly.

my %poes_own_events =
  ( EN_CHILD  , 1, EN_GC     , 1, EN_PARENT , 1, EN_SCPOLL , 1,
    EN_SIGNAL , 1, EN_START  , 1, EN_STOP   , 1,
  );

# These are ways a child may come or go.

sub CHILD_GAIN   () { 'gain'   }  # The session was inherited from another.
sub CHILD_LOSE   () { 'lose'   }  # The session is no longer this one's child.
sub CHILD_CREATE () { 'create' }  # The session was created as a child of this.

# Argument offsets for different types of internally generated events.
# -><- Exporting (EXPORT_OK) these would let people stop depending on
# positions for them.

sub EA_SEL_HANDLE () { 0 }
sub EA_SEL_MODE   () { 1 }

# Queues with this many events (or more) are considered to be "large",
# and different strategies are used to find events within them.

sub LARGE_QUEUE_SIZE () { 512 }

#------------------------------------------------------------------------------
# Debugging and configuration constants.

# Shorthand for defining a trace constant.
sub define_trace {
  no strict 'refs';
  foreach my $name (@_) {
    unless (defined *{"TRACE_$name"}{CODE}) {
      my $trace_value = $ENV{"POE_TRACE_$name"} || &TRACE_DEFAULT;
      eval "sub TRACE_$name () { $trace_value }";
    }
  }
}

# Shorthand for defining an assert constant.
sub define_assert {
  no strict 'refs';
  foreach my $name (@_) {
    unless (defined *{"ASSERT_$name"}{CODE}) {
      my $assert_value = $ENV{"POE_ASSERT_$name"} || &ASSERT_DEFAULT;
      eval "sub ASSERT_$name () { $assert_value }";
    }
  }
}

# Debugging flags for subsystems.  They're done as double evals here
# so that someone may define them before using POE::Kernel (or POE),
# and the pre-defined value will take precedence over the defaults
# here.

BEGIN {

  # TRACE_DEFAULT changes the default value for other TRACE_*
  # constants.  Since define_trace() uses TRACE_DEFAULT internally, it
  # can't be used to define TRACE_DEFAULT itself.

  my $trace_default = 0;
  $trace_default++ if defined $ENV{POE_TRACE_DEFAULT};
  defined &TRACE_DEFAULT or eval "sub TRACE_DEFAULT () { $trace_default }";

  define_trace
    qw(EVENTS GARBAGE PROFILE QUEUE REFCOUNT RETURNS SELECT SIGNALS ADHOC);

  # See the notes for TRACE_DEFAULT, except read ASSERT and assert
  # where you see TRACE and trace.

  my $assert_default = 0;
  $assert_default++ if defined $ENV{POE_ASSERT_DEFAULT};
  defined &ASSERT_DEFAULT or eval "sub ASSERT_DEFAULT () { $assert_default }";

  define_assert
    qw(EVENTS GARBAGE REFCOUNT RELATIONS SELECT SESSIONS RETURNS USAGE ADHOC);
};

#------------------------------------------------------------------------------
# Adapt POE::Kernel's personality to whichever event loop is present.

sub LOOP_EVENT  () { 'Event.pm' }
sub LOOP_GTK    () { 'Gtk.pm'   }
sub LOOP_POLL   () { 'Poll.pm'  }
sub LOOP_SELECT () { 'select()' }
sub LOOP_TK     () { 'Tk.pm'    }

BEGIN {
  if (exists $INC{'Gtk.pm'}) {
    require POE::Loop::Gtk;
    POE::Loop::Gtk->import();
  }

  if (exists $INC{'Tk.pm'}) {
    require POE::Loop::Tk;
    POE::Loop::Tk->import();
  }

  if (exists $INC{'Event.pm'}) {
    require POE::Loop::Event;
    POE::Loop::Event->import();
  }

  if (exists $INC{'IO/Poll.pm'}) {
    if ($^O eq 'MSWin32') {
      warn "IO::Poll has issues on $^O.  Using select() instead for now.\n";
    }
    else {
      require POE::Loop::Poll;
      POE::Loop::Poll->import();
    }
  }

  unless (defined &POE_LOOP) {
    require POE::Loop::Select;
    POE::Loop::Select->import();
  }
}

###############################################################################
# Accessors: Tagged extra reference counts accessors.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

### The count of all extra references used in the system.

my %kr_extra_refs;
#  ( $session =>
#    { $tag => $count,
#       ...,
#     },
#     ...,
#   );

### End-run leak checking.

END {
  foreach my $session (keys %kr_extra_refs) {
    warn "!!! Leaked extref: $session\n";
    foreach my $tag (keys %{$kr_extra_refs{$session}}) {
      warn "!!!\t`$tag' = $kr_extra_refs{$session}->{$tag}\n";
    }
  }
}

### Increment a session's tagged reference count.  If this is the
### first time the tag is used in the session, then increment the
### session's reference count as well.  Returns the tag's new
### reference count.

sub _data_extref_inc {
  my ($self, $session, $tag) = @_;
  my $refcount = ++$kr_extra_refs{$session}->{$tag};
  $self->_data_ses_refcount_inc($session) if $refcount == 1;
  TRACE_ADHOC and
    warn "<er> incremented extref ``$tag'' (now $refcount) for $session";
  return $refcount;
}

### Decrement a session's tagged reference count, removing it outright
### if the count reaches zero.  Return the new reference count or
### undef if the tag doesn't exist.

sub _data_extref_dec {
  my ($self, $session, $tag) = @_;
  confess "internal inconsistency"
    unless exists $kr_extra_refs{$session}->{$tag};
  my $refcount = --$kr_extra_refs{$session}->{$tag};
  TRACE_ADHOC and
    warn "<er> decremented extref ``$tag'' (now $refcount) for $session";
  $self->_data_extref_remove($session, $tag) unless $refcount;
  return $refcount;
}

### Remove an extra reference from a session, regardless of its count.

sub _data_extref_remove {
  my ($self, $session, $tag) = @_;
  confess "internal inconsistency"
    unless exists $kr_extra_refs{$session}->{$tag};
  delete $kr_extra_refs{$session}->{$tag};
  $self->_data_ses_refcount_dec($session);
  unless (keys %{$kr_extra_refs{$session}}) {
    delete $kr_extra_refs{$session};
    $self->_data_ses_collect_garbage($session);
  }
}

### Clear all the extra references from a session.

sub _data_extref_clear_session {
  my ($self, $session) = @_;
  return unless exists $kr_extra_refs{$session}; # avoid autoviv
  foreach (keys %{$kr_extra_refs{$session}}) {
    $self->_data_extref_remove($session, $_);
  }
  confess "internal inconsistency" if exists $kr_extra_refs{$session};
}

### Fetch the number of extra references held in the entire system.

sub _data_extref_count {
  return scalar keys %kr_extra_refs;
}

### Fetch the number of extra references held by a session.

sub _data_extref_count_ses {
  my ($self, $session) = @_;
  return exists $kr_extra_refs{$session};
}

} # Close scope.

###############################################################################
# Accessors: Session IDs.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

### Map session IDs to sessions.  Map sessions to session IDs.
### Maintain a sequence number for determining the next session ID.

my %kr_session_ids;
#  ( $session_id => $session_reference,
#    ...,
#  );

my %kr_session_to_id;
#  ( $session_ref => $session_id,
#    ...,
#  );

my $kr_sid_seq = 1;

### End-run leak checking.

END {
  # Don't bother if run() was never called.
  return unless $kr_run_warning & KR_RUN_CALLED;

  while (my ($sid, $ses) = each(%kr_session_ids)) {
    warn "!!! Leaked session ID: $sid = $ses\n";
  }
  while (my ($ses, $sid) = each(%kr_session_to_id)) {
    warn "!!! Leak sid cross-reference: $ses = $sid\n";
  }
}

### Allocate a new session ID.

sub _data_sid_allocate {
  my $self = shift;
  1 while exists $kr_session_ids{++$kr_sid_seq};
  return $kr_sid_seq;
}

### Set a session ID.

sub _data_sid_set {
  my ($self, $sid, $session) = @_;
  #cluck "+++++ $session = $sid";
  $kr_session_ids{$sid} = $session;
  $kr_session_to_id{$session} = $sid;
}

### Clear a session ID.

sub _data_sid_clear {
  my ($self, $session) = @_;
  my $sid = delete $kr_session_to_id{$session};
  #cluck "----- $session = $sid";
  confess "internal inconsistency" unless defined $sid;
  delete $kr_session_ids{$sid};
}

### Resolve a session ID into its session.

sub _data_sid_resolve {
  my ($self, $sid) = @_;
  return $kr_session_ids{$sid};
}

} # Close scope.

###############################################################################
# Accessors: Signals.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

### Map watched signal names to the sessions that are watching them
### and the events that must be delivered when they occur.

my %kr_signals;
#  ( $signal_name =>
#    { $session_reference => $event_name,
#      ...,
#    },
#    ...,
#  );

my %kr_sessions_to_signals;
#  ( $session =>
#    { $signal_name => $event_name,
#      ...,
#    },
#    ...,
#  );

# Bookkeeping per dispatched signal.

my @kr_signaled_sessions;           # The sessions touched by a signal.
my $kr_signal_total_handled;        # How many sessions handled a signal.
my $kr_signal_handled_implicitly;   # Whether it was handled implicitly.
my $kr_signal_handled_explicitly;   # Whether it was handled explicitly.
my $kr_signal_type;                 # The type of signal being dispatched.

# A list of special signal types.  Signals that aren't listed here are
# benign (they do not kill sessions at all).  "Terminal" signals are
# the ones that UNIX defaults to killing processes with.  Thus STOP is
# not terminal.

sub SIGTYPE_BENIGN      () { 0x00 }
sub SIGTYPE_TERMINAL    () { 0x01 }
sub SIGTYPE_NONMASKABLE () { 0x02 }

my %_signal_types =
  ( QUIT => SIGTYPE_TERMINAL,
    INT  => SIGTYPE_TERMINAL,
    KILL => SIGTYPE_TERMINAL,
    TERM => SIGTYPE_TERMINAL,
    HUP  => SIGTYPE_TERMINAL,
    IDLE => SIGTYPE_TERMINAL,
    ZOMBIE    => SIGTYPE_NONMASKABLE,
    UIDESTROY => SIGTYPE_NONMASKABLE,
  );

### End-run leak checking.

END {
  while (my ($sig, $sig_rec) = each(%kr_signals)) {
    warn "!!! Leaked signal $sig\n";
    while (my ($ses, $event) = each(%{$kr_signals{$sig}})) {
      warn "!!!\t$ses = $event\n";
    }
  }

  while (my ($ses, $sig_rec) = each(%kr_sessions_to_signals)) {
    warn "!!! Leaked signal cross-reference: $ses\n";
    while (my ($sig, $event) = each(%{$kr_signals{$ses}})) {
      warn "!!!\t$sig = $event\n";
    }
  }
}

### Add a signal to a session.

sub _data_sig_add {
  my ($self, $session, $signal, $event) = @_;
  $kr_sessions_to_signals{$session}->{$signal} = $event;
  $kr_signals{$signal}->{$session} = $event;
}

### Remove a signal from a session.

sub _data_sig_remove {
  my ($self, $session, $signal) = @_;

  delete $kr_sessions_to_signals{$session}->{$signal};
  delete $kr_sessions_to_signals{$session}
    unless keys(%{$kr_sessions_to_signals{$session}});

  delete $kr_signals{$signal}->{$session};
  delete $kr_signals{$signal} unless keys %{$kr_signals{$signal}};
}

### Clear all the signals from a session.

sub _data_sig_clear_session {
  my ($self, $session) = @_;
  return unless exists $kr_sessions_to_signals{$session}; # avoid autoviv
  foreach (keys %{$kr_sessions_to_signals{$session}}) {
    $self->_data_sig_remove($session, $_);
  }
}

### Return a signal's type, or SIGTYPE_BENIGN if it's not special.

sub _data_sig_type {
  my ($self, $signal) = @_;
  return $_signal_types{$signal} || SIGTYPE_BENIGN;
}

### Flag a signal as being handled by some session.

sub _data_sig_handled {
  my $self = shift;
  $kr_signal_total_handled = 1;
  $kr_signal_handled_explicitly = 1;
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

### Which sessions are watching a signal?

sub _data_sig_watchers {
  my ($self, $signal) = @_;
  return each %{$kr_signals{$signal}};
}

### Determine if a given session is watching a signal.  This uses a
### two-step exists so that the longer one does not autovivify keys in
### the shorter one.

sub _data_sig_watched_by_session {
  my ($self, $signal, $session) = @_;
  return( exists($kr_signals{$signal}) &&
          exists($kr_signals{$signal}->{$session})
        )
}

### Clear the flags that determine if/how a session handled a signal.

sub _data_sig_clear_handled_flags {
  undef $kr_signal_handled_implicitly;
  undef $kr_signal_handled_explicitly;
}

### Destroy sessions touched by a nonmaskable signal or by an
### unhandled terminal signal.  Check for garbage-collection on
### sessions which aren't to be terminated.

sub _data_sig_free_terminated_sessions {
  my $self = shift;

  if ( ($kr_signal_type & SIGTYPE_NONMASKABLE) or
       ( $kr_signal_type & SIGTYPE_TERMINAL and !$kr_signal_total_handled )
     ) {
    foreach my $dead_session (@kr_signaled_sessions) {
      next unless $self->_data_ses_exists($dead_session);
      TRACE_ADHOC and
        warn "<sg> stopping signaled session ", $dead_session->ID;
      $self->_data_ses_stop($dead_session);
    }
  }
  else {
    foreach my $touched_session (@kr_signaled_sessions) {
      $self->_data_ses_collect_garbage($touched_session);
    }
  }
}

### A signal has touched a session.  Record this fact for later
### destruction tests.

sub _data_sig_touched_session {
  my ($self, $session, $handler_retval) = @_;

  push @kr_signaled_sessions, $session;
  $kr_signal_total_handled      += !!$handler_retval;
  $kr_signal_handled_implicitly += !!$handler_retval;

  unless ($kr_signal_handled_explicitly) {
    if ($kr_signal_handled_implicitly) {
      # -><- DEPRECATION WARNING GOES HERE
      # warn( { % ssid % } . " implicitly handled SIG$etc->[0]\n" );
    }
  }
}

} # Close scope.

###############################################################################
# Accessors: Aliases.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

### The table of session aliases, and the sessions they refer to.

my %kr_aliases;
#  ( $alias => $session_ref,
#    ...,
#  );

my %kr_ses_to_alias;
#  ( $session_ref =>
#    { $alias => $placeholder_value,
#      ...,
#    },
#    ...,
#  );

### End-run leak checking.

END {
  while (my ($alias, $ses) = each(%kr_aliases)) {
    warn "!!! Leaked alias: $alias = $ses\n";
  }
  while (my ($ses, $alias_rec) = each(%kr_ses_to_alias)) {
    my @aliases = keys(%$alias_rec);
    warn "!!! Leaked alias cross-reference: $ses (@aliases)\n";
  }
}

### Add an alias to a session.

sub _data_alias_add {
  my ($self, $session, $alias) = @_;
  $self->_data_ses_refcount_inc($session);
  $kr_aliases{$alias} = $session;
  $kr_ses_to_alias{$session}->{$alias} = 1;
}

### Remove an alias from a session.

sub _data_alias_remove {
  my ($self, $session, $alias) = @_;
  delete $kr_aliases{$alias};
  delete $kr_ses_to_alias{$session}->{$alias};
  unless (keys %{$kr_ses_to_alias{$session}}) {
    delete $kr_ses_to_alias{$session};
  }
  $self->_data_ses_refcount_dec($session);
}

### Clear all the aliases from a session.

sub _data_alias_clear_session {
  my ($self, $session) = @_;
  return unless exists $kr_ses_to_alias{$session}; # avoid autoviv
  foreach (keys %{$kr_ses_to_alias{$session}}) {
    $self->_data_alias_remove($session, $_);
  }
}

### Resolve an alias.  Just an alias.

sub _data_alias_resolve {
  my ($self, $alias) = @_;
  return undef unless exists $kr_aliases{$alias};
  return $kr_aliases{$alias};
}

### Return a list of aliases for a session.

sub _data_alias_list {
  my ($self, $session) = @_;
  return () unless exists $kr_ses_to_alias{$session};
  return sort keys %{$kr_ses_to_alias{$session}};
}

### Return the number of aliases for a session.

sub _data_alias_count_ses {
  my ($self, $session) = @_;
  return 0 unless exists $kr_ses_to_alias{$session};
  return scalar keys %{$kr_ses_to_alias{$session}};
}

### Return a session's ID in a form suitable for logging.

sub _data_alias_loggable {
  my ($self, $session) = @_;
  confess "internal inconsistency" unless ref($session);
  "session " . $session->ID . " (" .
    ( (exists $kr_ses_to_alias{$session})
      ? join(", ", keys(%{$kr_ses_to_alias{$session}}))
      : $session
    ) . ")"
}

} # Close scope.

###############################################################################
# Accessors: File descriptor tables.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

### Fileno structure.  This tracks the sessions that are watchin a
### file, by its file number.  It used to track by file handle, but
### several handles can point to the same underlying fileno.  This is
### more unique.

my %kr_filenos;

sub FNO_VEC_RD       () { VEC_RD }  # [ [ (fileno read mode structure)
# --- BEGIN SUB STRUCT 1 ---        #
sub FVC_REFCOUNT     () { 0      }  #     $fileno_total_use_count,
sub FVC_ST_ACTUAL    () { 1      }  #     $requested_file_state (see HS_PAUSED)
sub FVC_ST_REQUEST   () { 2      }  #     $actual_file_state (see HS_PAUSED)
sub FVC_EV_COUNT     () { 3      }  #     $number_of_pending_events,
sub FVC_SESSIONS     () { 4      }  #     { $session_watching_this_handle =>
# --- BEGIN SUB STRUCT 2 ---        #
sub HSS_HANDLE       () { 0      }  #       [ $blessed_handle,
sub HSS_SESSION      () { 1      }  #         $blessed_session,
sub HSS_STATE        () { 2      }  #         $event_name,
                                    #       ],
# --- CEASE SUB STRUCT 2 ---        #     },
# --- CEASE SUB STRUCT 1 ---        #   ],
                                    #
sub FNO_VEC_WR       () { VEC_WR }  #   [ (write mode structure is the same)
                                    #   ],
                                    #
sub FNO_VEC_EX       () { VEC_EX }  #   [ (expedite mode struct is the same)
                                    #   ],
                                    #
sub FNO_TOT_REFCOUNT () { 3      }  #   $total_number_of_file_watchers,
                                    # ]

### These are the values for FVC_ST_ACTUAL and FVC_ST_REQUEST.

sub HS_STOPPED   () { 0x00 }   # The file has stopped generating events.
sub HS_PAUSED    () { 0x01 }   # The file temporarily stopped making events.
sub HS_RUNNING   () { 0x02 }   # The file is running and can generate events.

### Handle to session.

my %kr_ses_to_handle;

                            #    { $file_handle =>
# --- BEGIN SUB STRUCT ---  #      [
sub SH_HANDLE     () {  0 } #        $blessed_file_handle,
sub SH_REFCOUNT   () {  1 } #        $total_reference_count,
sub SH_VECCOUNT   () {  2 } #        [ $read_reference_count,     (VEC_RD)
                            #          $write_reference_count,    (VEC_WR)
                            #          $expedite_reference_count, (VEC_EX)
# --- CEASE SUB STRUCT ---  #        ],
                            #      ],
                            #      ...
                            #    },

### End-run leak checking.

END {
  while (my ($fd, $fd_rec) = each(%kr_filenos)) {
    my ($rd, $wr, $ex, $tot) = @$fd_rec;
    warn "!!! Leaked fileno: $fd (total refcnt=$tot)\n";

    warn( "!!!\tRead:\n",
          "!!!\t\trefcnt  = $rd->[FVC_REFCOUNT]\n",
          "!!!\t\tev cnt  = $rd->[FVC_EV_COUNT]\n",
        );
    while (my ($ses, $ses_rec) = each(%{$rd->[FVC_SESSIONS]})) {
      warn( "!!!\t\tsession = $ses\n",
            "!!!\t\t\thandle  = $ses_rec->[HSS_HANDLE]\n",
            "!!!\t\t\tsession = $ses_rec->[HSS_SESSION]\n",
            "!!!\t\t\tevent   = $ses_rec->[HSS_STATE]\n",
          );
    }

    warn( "!!!\tWrite:\n",
          "!!!\t\trefcnt  = $wr->[FVC_REFCOUNT]\n",
          "!!!\t\tev cnt  = $wr->[FVC_EV_COUNT]\n",
        );
    while (my ($ses, $ses_rec) = each(%{$wr->[FVC_SESSIONS]})) {
      warn( "!!!\t\tsession = $ses\n",
            "!!!\t\t\thandle  = $ses_rec->[HSS_HANDLE]\n",
            "!!!\t\t\tsession = $ses_rec->[HSS_SESSION]\n",
            "!!!\t\t\tevent   = $ses_rec->[HSS_STATE]\n",
          );
    }

    warn( "!!!\tException:\n",
          "!!!\t\trefcnt  = $ex->[FVC_REFCOUNT]\n",
          "!!!\t\tev cnt  = $ex->[FVC_EV_COUNT]\n",
        );
    while (my ($ses, $ses_rec) = each(%{$ex->[FVC_SESSIONS]})) {
      warn( "!!!\t\tsession = $ses\n",
            "!!!\t\t\thandle  = $ses_rec->[HSS_HANDLE]\n",
            "!!!\t\t\tsession = $ses_rec->[HSS_SESSION]\n",
            "!!!\t\t\tevent   = $ses_rec->[HSS_STATE]\n",
          );
    }
  }

  while (my ($ses, $hnd_rec) = each(%kr_ses_to_handle)) {
    warn "!!! Leaked handle in $ses\n";
    while (my ($hnd, $rc) = each(%$hnd_rec)) {
      warn( "!!!\tHandle: $hnd (tot refcnt=$rc->[SH_REFCOUNT])\n",
            "!!!\t\tRead      refcnt: $rc->[SH_VECCOUNT]->[VEC_RD]\n",
            "!!!\t\tWrite     refcnt: $rc->[SH_VECCOUNT]->[VEC_WR]\n",
            "!!!\t\tException refcnt: $rc->[SH_VECCOUNT]->[VEC_EX]\n",
          );
    }
  }
}

### Ensure a handle's actual state matches its requested one.  Pause
### or resume the handle as necessary.

sub _data_handle_resume_requested_state {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  # Skip the rest if we aren't watching the file descriptor.  This
  # seems like a kludge: should we even be called if the descriptor
  # isn't watched?
  return unless exists $kr_filenos{$fileno};

  my $kr_fno_vec  = $kr_filenos{$fileno}->[$mode];

  if (TRACE_SELECT) {
    warn( "<fd> decrementing event count in mode ($mode) ",
          "for fileno (", $fileno, ") from count (",
          $kr_fno_vec->[FVC_EV_COUNT], ")"
        );
  }

  # If all events for the fileno/mode pair have been delivered, then
  # resume the filehandle's watcher.  This decrements FVC_EV_COUNT
  # because the event has just been dispatched.  This makes sense.

  unless (--$kr_fno_vec->[FVC_EV_COUNT]) {
    if ($kr_fno_vec->[FVC_ST_REQUEST] & HS_PAUSED) {
      $self->loop_pause_filehandle_watcher($handle, $mode);
      $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
    }
    elsif ($kr_fno_vec->[FVC_ST_REQUEST] & HS_RUNNING) {
      $self->loop_resume_filehandle_watcher($handle, $mode);
      $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
    }
    else {
      confess "internal consistency error";
    }
  }
  elsif ($kr_fno_vec->[FVC_EV_COUNT] < 0) {
    confess "handle event count went below zero";
  }
}

### Enqueue "select" events for a list of file descriptors in a given
### access mode.

sub _data_handle_enqueue_ready {
  my ($self, $mode, @filenos) = @_;

  foreach my $fileno (@filenos) {
    confess "internal inconsistency: undefined fileno" unless defined $fileno;
    my $kr_fno_vec = $kr_filenos{$fileno}->[$mode];

    # Gather all the events to emit for this fileno/mode pair.

    my @selects = map { values %$_ } values %{ $kr_fno_vec->[FVC_SESSIONS] };

    # Emit them.

    foreach my $select (@selects) {
      $self->_data_ev_enqueue
        ( $select->[HSS_SESSION], $select->[HSS_SESSION],
          $select->[HSS_STATE], ET_SELECT,
          [ $select->[HSS_HANDLE],  # EA_SEL_HANDLE
            $mode,                  # EA_SEL_MODE
          ],
          __FILE__, __LINE__, time(),
        );

      # Count the enqueued event.  This increments FVC_EV_COUNT
      # because an event has just been enqueued.  This makes sense.

      unless ($kr_fno_vec->[FVC_EV_COUNT]++) {
        my $handle = $select->[HSS_HANDLE];
        $self->loop_pause_filehandle_watcher($handle, $mode);
        $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
      }

      if (TRACE_SELECT) {
        warn( "<fd> incremented event count in mode ($mode) ",
              "for fileno ($fileno) to count ($kr_fno_vec->[FVC_EV_COUNT])"
            );
      }
    }
  }
}

### Test whether POE is tracking a file handle.

sub _data_handle_is_good {
  my ($self, $handle, $mode) = @_;

  # Don't bother if the kernel isn't tracking the file.
  return 0 unless exists $kr_filenos{fileno $handle};

  # Don't bother if the kernel isn't tracking the file mode.
  return 0 unless $kr_filenos{fileno $handle}->[$mode]->[FVC_REFCOUNT];

  return 1;
}

### Add a select to the session, and possibly begin a watcher.

sub _data_handle_add {
  my ($self, $handle, $mode, $session, $event) = @_;
  my $fd = fileno($handle);

  unless (exists $kr_filenos{$fd}) {

    $kr_filenos{$fd} =
      [ [ 0,          # FVC_REFCOUNT    VEC_RD
          HS_PAUSED,  # FVC_ST_ACTUAL
          HS_PAUSED,  # FVC_ST_REQUEST
          0,          # FVC_EV_COUNT
          { },        # FVC_SESSIONS
        ],
        [ 0,          # FVC_REFCOUNT    VEC_WR
          HS_PAUSED,  # FVC_ST_ACTUAL
          HS_PAUSED,  # FVC_ST_REQUEST
          0,          # FVC_EV_COUNT
          { },        # FVC_SESSIONS
        ],
        [ 0,          # FVC_REFCOUNT    VEC_EX
          HS_PAUSED,  # FVC_ST_ACTUAL
          HS_PAUSED,  # FVC_ST_REQUEST
          0,          # FVC_EV_COUNT
          { },        # FVC_SESSIONS
        ],
        0,            # FNO_TOT_REFCOUNT
      ];

    if (TRACE_SELECT) {
      warn "<sl> adding fd (", $fd, ")";
    }

    # For DOSISH systems like OS/2.  Wrapped in eval{} in case it's a
    # tied handle that doesn't support binmode.
    eval { binmode *$handle };

    # Turn off blocking unless it's tied or a plain file.
    unless (tied *$handle or -f $handle) {

      # Make the handle stop blocking, the Windows way.
      if (RUNNING_IN_HELL) {
        my $set_it = "1";

        # 126 is FIONBIO (some docs say 0x7F << 16)
        ioctl( $handle,
               0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
               $set_it
             ) or confess "Can't set the handle non-blocking: $!";
      }

      # Make the handle stop blocking, the POSIX way.
      else {
        my $flags = fcntl($handle, F_GETFL, 0)
          or confess "fcntl($handle, F_GETFL, etc.) fails: $!\n";
        until (fcntl($handle, F_SETFL, $flags | O_NONBLOCK)) {
          confess "fcntl($handle, FSETFL, etc) fails: $!"
            unless $! == EAGAIN or $! == EWOULDBLOCK;
        }
      }
    }

    # Turn off buffering.
    select((select($handle), $| = 1)[0]);
  }

  # Cache some high-level lookups.
  my $kr_fileno  = $kr_filenos{$fd};
  my $kr_fno_vec = $kr_fileno->[$mode];

  # The session is already watching this fileno in this mode.

  if ($kr_fno_vec->[FVC_SESSIONS]->{$session}) {

    # The session is also watching it by the same handle.  Treat this
    # as a "resume" in this mode.

    if (exists $kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle}) {
      if (TRACE_SELECT) {
        warn( "<fd> fileno(" . $fd . ") mode($mode) " .
              "count($kr_fno_vec->[FVC_EV_COUNT])"
            );
      }
      unless ($kr_fno_vec->[FVC_EV_COUNT]) {
        $self->loop_resume_filehandle_watcher($handle, $mode);
      }
      $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
    }

    # The session is watching it by a different handle.  It can't be
    # done yet, but maybe later when drivers are added to the mix.

    else {
      confess "can't watch the same handle in the same mode 2+ times yet";
    }
  }

  # The session is not watching this fileno in this mode.  Record
  # the session/handle pair.

  else {
    $kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle} =
      [ $handle,      # HSS_HANDLE
        $session,     # HSS_SESSION
        $event,       # HSS_STATE
      ];

    # Fix reference counts.
    $kr_fileno->[FNO_TOT_REFCOUNT]++;
    $kr_fno_vec->[FVC_REFCOUNT]++;

    # If this is the first time a file is watched in this mode, then
    # have the event loop bridge watch it.

    if ($kr_fno_vec->[FVC_REFCOUNT] == 1) {
      $self->loop_watch_filehandle($handle, $mode);
      $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
      $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
    }
  }

  # If the session hasn't already been watching the filehandle, then
  # register the filehandle in the session's structure.

  unless (exists $kr_ses_to_handle{$session}->{$handle}) {
    $kr_ses_to_handle{$session}->{$handle} =
      [ $handle,  # SH_HANDLE
        0,        # SH_REFCOUNT
        [ 0,      # SH_VECCOUNT / VEC_RD
          0,      # SH_VECCOUNT / VEC_WR
          0       # SH_VECCOUNT / VEC_EX
        ]
      ];
    $self->_data_ses_refcount_inc($session);
  }

  # Modify the session's handle structure's reference counts, so the
  # session knows it has a reason to live.

  my $ss_handle = $kr_ses_to_handle{$session}->{$handle};
  unless ($ss_handle->[SH_VECCOUNT]->[$mode]) {
    $ss_handle->[SH_VECCOUNT]->[$mode]++;
    $ss_handle->[SH_REFCOUNT]++;
  }
}

### Remove a select from the kernel, and possibly trigger the
### session's destruction.

sub _data_handle_remove {
  my ($self, $handle, $mode, $session) = @_;
  my $fd = fileno($handle);

  # Make sure the handle is deregistered with the kernel.

  if (exists $kr_filenos{$fd}) {
    my $kr_fileno  = $kr_filenos{$fd};
    my $kr_fno_vec = $kr_fileno->[$mode];

    # Make sure the handle was registered to the requested session.

    if ( exists($kr_fno_vec->[FVC_SESSIONS]->{$session}) and
         exists($kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle})
       ) {

      # Remove the handle from the kernel's session record.

      my $handle_rec =
        delete $kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle};

      my $kill_session = $handle_rec->[HSS_SESSION];
      my $kill_event   = $handle_rec->[HSS_STATE];

      # Remove any events destined for that handle.  Decrement
      # FVC_EV_COUNT for each, because we've removed them.  This makes
      # sense.

      my $my_select = sub {
        return 0 unless $_[0]->[EV_TYPE]    &  ET_SELECT;
        return 0 unless $_[0]->[EV_SESSION] == $kill_session;
        return 0 unless $_[0]->[EV_NAME]    eq $kill_event;
        return 0 unless $_[0]->[EV_ARGS]->[EA_SEL_HANDLE] == $handle;
        return 0 unless $_[0]->[EV_ARGS]->[EA_SEL_MODE]   == $mode;
        return 1;
      };

      foreach ($kr_queue->remove_items($my_select)) {
        my ($time, $id, $event) = @$_;
        $self->_data_ev_refcount_dec( $event->[EV_SESSION],
                                      $event->[EV_SOURCE]
                                    );
        TRACE_EVENTS and
          warn "<ev> removing select event $id ``$event->[EV_NAME]''";

        $kr_fno_vec->[FVC_EV_COUNT]--;

        if (TRACE_SELECT) {
          confess( "<fd> fileno $fd mode $mode event count went to ",
                   $kr_fno_vec->[FVC_EV_COUNT]
                 );
        }

        if (ASSERT_REFCOUNT) {
          confess "<fd> fileno $fd mode $mode event count went below zero"
            if $kr_fno_vec->[FVC_EV_COUNT] < 0;
        }
      }

      # Decrement the handle's reference count.

      $kr_fno_vec->[FVC_REFCOUNT]--;

      if (ASSERT_REFCOUNT) {
        confess "fileno mode refcount went below zero"
          if $kr_fno_vec->[FVC_REFCOUNT] < 0;
      }

      # If the "mode" count drops to zero, then stop selecting the
      # handle.

      unless ($kr_fno_vec->[FVC_REFCOUNT]) {
        $self->loop_ignore_filehandle($handle, $mode);
        $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
        $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;

        # The session is not watching handles anymore.  Remove the
        # session entirely the fileno structure.
        delete $kr_fno_vec->[FVC_SESSIONS]->{$session}
          unless keys %{$kr_fno_vec->[FVC_SESSIONS]->{$session}};
      }

      # Decrement the kernel record's handle reference count.  If the
      # handle is done being used, then delete it from the kernel's
      # record structure.  This initiates Perl's garbage collection on
      # it, as soon as whatever else in "user space" frees it.

      $kr_fileno->[FNO_TOT_REFCOUNT]--;

      if (ASSERT_REFCOUNT) {
        confess "fileno refcount went below zero"
          if $kr_fileno->[FNO_TOT_REFCOUNT] < 0;
      }

      unless ($kr_fileno->[FNO_TOT_REFCOUNT]) {
        if (TRACE_SELECT) {
          warn "<sl> deleting fileno (", $fd, ")";
        }
        delete $kr_filenos{$fd};
      }
    }
  }

  # SS_HANDLES - Remove the select from the session, assuming there is
  # a session to remove it from.  -><- Key it on fileno?

  if ( exists($kr_ses_to_handle{$session}) and
       exists($kr_ses_to_handle{$session}->{$handle})
     ) {

    # Remove it from the session's read, write or expedite mode.

    my $ss_handle = $kr_ses_to_handle{$session}->{$handle};
    if ($ss_handle->[SH_VECCOUNT]->[$mode]) {

      # Hmm... what is this?  Was POE going to support multiple selects?

      $ss_handle->[SH_VECCOUNT]->[$mode] = 0;

      # Decrement the reference count, and delete the handle if it's done.

      $ss_handle->[SH_REFCOUNT]--;

      if (ASSERT_REFCOUNT) {
        confess "refcount went below zero" if $ss_handle->[SH_REFCOUNT] < 0;
      }

      unless ($ss_handle->[SH_REFCOUNT]) {
        delete $kr_ses_to_handle{$session}->{$handle};
        $self->_data_ses_refcount_dec($session);
        delete $kr_ses_to_handle{$session}
          unless keys %{$kr_ses_to_handle{$session}};
      }
    }
  }
}

### Resume a filehandle.  If there are no events in the queue for this
### handle/mode pair, then we go ahead and set the actual state now.
### Otherwise it must wait until the queue empties.

sub _data_handle_resume {
  my ($self, $handle, $mode) = @_;

  my $kr_fileno = $kr_filenos{fileno($handle)};
  my $kr_fno_vec = $kr_fileno->[$mode];

  if (TRACE_SELECT) {
    warn( "<fd> resume test: fileno(" . fileno($handle) . ") mode($mode) " .
          "count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }

  # Resume the handle if there are no events for it.
  unless ($kr_fno_vec->[FVC_EV_COUNT]) {
    $self->loop_resume_filehandle_watcher($handle, $mode);
  }

  # Either way we set the handle's requested state to "running".
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

### Pause a filehandle.  If there are no events in the queue for this
### handle/mode pair, then we go ahead and set the actual state now.
### Otherwise it must wait until the queue empties.

sub _data_handle_pause {
  my ($self, $handle, $mode) = @_;

  my $kr_fileno = $kr_filenos{fileno($handle)};
  my $kr_fno_vec = $kr_fileno->[$mode];

  if (TRACE_SELECT) {
    warn( "<fd> pause test: fileno(" . fileno($handle) . ") mode($mode) " .
          "count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }

  unless ($kr_fno_vec->[FVC_EV_COUNT]) {
    $self->loop_pause_filehandle_watcher($handle, $mode);
  }

  # Correct the requested state so it matches the actual one.

  $kr_fno_vec->[FVC_ST_REQUEST] = HS_PAUSED;
}

### Return the number of active filehandles in the entire system.

sub _data_handle_count {
  return scalar keys %kr_filenos;
}

### Return the number of active handles for a single session.

sub _data_handle_count_ses {
  my ($self, $session) = @_;
  return 0 unless exists $kr_ses_to_handle{$session};
  return scalar keys %{$kr_ses_to_handle{$session}};
}

### Clear all the handles owned by a session.

sub _data_handle_clear_session {
  my ($self, $session) = @_;
  return unless exists $kr_ses_to_handle{$session}; # avoid autoviv
  my @handles = values %{$kr_ses_to_handle{$session}};
  foreach (@handles) {
    my $handle = $_->[SH_HANDLE];
    my $refcount = $_->[SH_VECCOUNT];

    $self->_data_handle_remove($handle, VEC_RD, $session)
      if $refcount->[VEC_RD];
    $self->_data_handle_remove($handle, VEC_WR, $session)
      if $refcount->[VEC_WR];
    $self->_data_handle_remove($handle, VEC_EX, $session)
      if $refcount->[VEC_EX];
  }
}

} # Close scope.

###############################################################################
# Accessors: Events.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

my %event_count;
#  ( $session => $count,
#    ...,
#  );

my %post_count;
#  ( $session => $count,
#    ...,
#  );

### End-run leak checking.

END {
  # Don't bother if run() was never called.
  return unless $kr_run_warning & KR_RUN_CALLED;

  while (my ($ses, $cnt) = each(%event_count)) {
    warn "!!! Leaked event-to count: $ses = $cnt\n";
  }

  while (my ($ses, $cnt) = each(%post_count)) {
    warn "!!! Leaked event-from count: $ses = $cnt\n";
  }
}

### Enqueue an event.

sub _data_ev_enqueue {
  my ( $self,
       $session, $source_session, $event, $type, $etc, $file, $line,
       $time
     ) = @_;

  unless ($self->_data_ses_exists($session)) {
    confess
      "<ev> can't enqueue event ``$event'' for nonexistent session $session\n";
  }

  # This is awkward, but faster than using the fields individually.
  my $event_to_enqueue = [ @_[1..7] ];

  my $old_head_priority = $kr_queue->get_next_priority();
  my $new_id = $kr_queue->enqueue($time, $event_to_enqueue);

  if (TRACE_EVENTS) {
    warn( "<ev> enqueued event $new_id ``$event'' from session ",
          $source_session->ID, " to ", $self->_data_alias_loggable($session),
          " at $time"
        );
  }

  if ($kr_queue->get_item_count() == 1) {
    $self->loop_resume_time_watcher($time);
  }
  elsif ($time < $old_head_priority) {
    $self->loop_reset_time_watcher($time);
  }

  $self->_data_ses_refcount_inc($session);
  $event_count{$session}++;

  $self->_data_ses_refcount_inc($source_session);
  $post_count{$source_session}++;

  return $new_id;
}

### Remove events sent to or from a specific session.

sub _data_ev_clear_session {
  my ($self, $session) = @_;

  my $my_event = sub {
    ($_[0]->[EV_SESSION] == $session) || ($_[0]->[EV_SOURCE] == $session)
  };

  my @removed = $kr_queue->remove_items($my_event);
  foreach (@removed) {
    $self->_data_ev_refcount_dec( $_->[ITEM_PAYLOAD]->[EV_SOURCE],
                                  $_->[ITEM_PAYLOAD]->[EV_SESSION]
                                );
  }
}

### Remove a specific alarm by its name.  This is in the events
### section because alarms are currently implemented as events with
### future due times.

sub _data_ev_clear_alarm_by_name {
  my ($self, $session, $alarm_name) = @_;

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION] == $session;
    return 0 unless $_[0]->[EV_NAME] eq $alarm_name;
    return 1;
  };

  foreach ($kr_queue->remove_items($my_alarm)) {
    $self->_data_ev_refcount_dec( $_->[ITEM_PAYLOAD]->[EV_SOURCE],
                                  $_->[ITEM_PAYLOAD]->[EV_SESSION]
                                );
  }
}

### Remove a specific alarm by its ID.  This is in the events section
### because alarms are currently implemented as events with future due
### times.

sub _data_ev_clear_alarm_by_id {
  my ($self, $session, $alarm_id) = @_;

  my $my_alarm = sub {
    $_[0]->[EV_SESSION] == $session;
  };

  my ($time, $id, $event) = $kr_queue->remove_item($alarm_id, $my_alarm);
  return unless defined $time;

  $self->_data_ev_refcount_dec($event->[EV_SOURCE], $event->[EV_SESSION]);
  return ($time, $event);
}

### Remove all the alarms for a session.  Whoot!

sub _data_ev_clear_alarm_by_session {
  my ($self, $session) = @_;

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION] == $session;
    return 1;
  };

  my @removed;
  foreach ($kr_queue->remove_items($my_alarm)) {
    $self->_data_ev_refcount_dec( $_->[ITEM_PAYLOAD]->[EV_SOURCE],
                                  $_->[ITEM_PAYLOAD]->[EV_SESSION]
                                );
    my ($time, $id, $event) = @$_;
    push @removed, [ $event->[EV_NAME], $time, @{$event->[EV_ARGS]} ];
  }

  return @removed;
}

### Decrement a post refcount

sub _data_ev_refcount_dec {
  my ($self, $source_session, $dest_session) = @_;

  confess $dest_session unless exists $event_count{$dest_session};
  confess $source_session unless exists $post_count{$source_session};

  $self->_data_ses_refcount_dec($dest_session);
  unless (--$event_count{$dest_session}) {
    delete $event_count{$dest_session};
  }

  $self->_data_ses_refcount_dec($source_session);
  unless (--$post_count{$source_session}) {
    delete $post_count{$source_session};
  }
}

### Fetch the number of pending events sent to a session.

sub _data_ev_get_count_to {
  my ($self, $session) = @_;
  return $event_count{$session} || 0;
}

### Fetch the number of pending events sent from a session.

sub _data_ev_get_count_from {
  my ($self, $session) = @_;
  return $post_count{$session} || 0;
}

### Dispatch events that are due for "now" or earlier.

sub _data_ev_dispatch_due {
  my $self = shift;
  my $now = time();
  while (defined(my $next_time = $kr_queue->get_next_priority())) {
    last if $next_time > $now;
    my ($time, $id, $event) = $kr_queue->dequeue_next();
    TRACE_EVENTS and warn "<ev> dispatching event $id";
    $self->_data_ev_refcount_dec($event->[EV_SOURCE], $event->[EV_SESSION]);
    $self->_dispatch_event(@$event, $time, $id);
  }
}

} # Close scope.

###############################################################################
# Accessors: Sessions.
###############################################################################

{ # In its own scope for debugging.  This makes the data members private.

### Session structure.

my %kr_sessions;
#  { $session =>
#    [ $blessed_session,         SS_SESSION
#      $total_reference_count,   SS_REFCOUNT
#      $parent_session,          SS_PARENT
#      { $child_session => $blessed_ref,     SS_CHILDREN
#        ...,
#      },
#      { $process_id => $placeholder_value,  SS_PROCESSES
#        ...,
#      },
#      $unique_session_id,       SS_ID
#    ],
#    ...,
#  };

sub SS_SESSION    () { 0 }
sub SS_REFCOUNT   () { 1 }
sub SS_PARENT     () { 2 }
sub SS_CHILDREN   () { 3 }
sub SS_PROCESSES  () { 4 }
sub SS_ID         () { 5 }

### End-run leak checking.

END {
  # Don't bother if run() was never called.
  return unless $kr_run_warning & KR_RUN_CALLED;

  while (my ($ses, $ses_rec) = each(%kr_sessions)) {
    warn( "!!! Leaked session: $ses\n",
          "!!!\trefcnt = $ses_rec->[SS_REFCOUNT]\n",
          "!!!\tparent = $ses_rec->[SS_PARENT]\n",
          "!!!\tchilds = ", join("; ", keys(%{$ses_rec->[SS_CHILDREN]})), "\n",
          "!!!\tprocs  = ", join("; ", keys(%{$ses_rec->[SS_PROCESSES]})),"\n",
        );
  }
}

### Enter a new session into the back-end stuff.

sub _data_ses_allocate {
  my ($self, $session, $sid, $parent) = @_;

  $kr_sessions{$session} =
    [ $session,  # SS_SESSION
      0,         # SS_REFCOUNT
      $parent,   # SS_PARENT
      { },       # SS_CHILDREN
      { },       # SS_PROCESSES
      $sid,      # SS_ID
    ];

  # For the ID to session reference lookup.
  $self->_data_sid_set($sid, $session);

  # Manage parent/child relationship.
  if (defined $parent) {
    confess "parent $parent does not exist"
      unless exists $kr_sessions{$parent};
    $kr_sessions{$parent}->[SS_CHILDREN]->{$session} = $session;
    $self->_data_ses_refcount_inc($parent);
  }
}

### Release a session's resources, and remove it.  This doesn't do
### garbage collection for the session itself because that should
### already have happened.

sub _data_ses_free {
  my ($self, $session) = @_;

  TRACE_ADHOC and warn "<fr> freeing session $session";

  # Manage parent/child relationships.

  my $parent = $kr_sessions{$session}->[SS_PARENT];
  my @children = $self->_data_ses_get_children($session);
  if (defined $parent) {
    confess "session is its own parent" if $parent == $session;
    confess
      ( $self->_data_alias_loggable($session), " isn't a child of ",
        $self->_data_alias_loggable($parent), " (it's a child of ",
        $self->_data_alias_loggable($self->_data_ses_get_parent($session)),
        ")"
      ) unless $self->_data_ses_is_child($parent, $session);

    # Remove the departing session from its parent.

    confess "internal inconsistency ($parent)"
      unless exists $kr_sessions{$parent};
    confess "internal inconsistency ($parent/$session)"
      unless delete $kr_sessions{$parent}->[SS_CHILDREN]->{$session};
    $self->_data_ses_refcount_dec($parent);

    # Move the departing session's children to its parent.

    foreach (@children) {
      $self->_data_ses_move_child($_, $parent)
    }
  }
  else {
    confess "no parent to give children to" if @children;
  }

  # Things which do not hold reference counts.

  $self->_data_sid_clear($session);            # Remove from SID tables.
  $self->_data_sig_clear_session($session);    # Remove all leftover signals.

  # Things which dohold reference counts.

  $self->_data_alias_clear_session($session);  # Remove all leftover aliases.
  $self->_data_extref_clear_session($session); # Remove all leftover extrefs.
  $self->_data_handle_clear_session($session); # Remove all leftover handles.
  $self->_data_ev_clear_session($session);     # Remove all leftover events.

  # Remove the session itself.

  delete $kr_sessions{$session};

  # GC the parent, if there is one.
  if (defined $parent) {
    $self->_data_ses_collect_garbage($parent);
  }

  # Stop the main loop if everything is gone.
  unless (keys %kr_sessions) {
    $self->loop_halt();
  }
}

### Move a session to a new parent.

sub _data_ses_move_child {
  my ($self, $session, $new_parent) = @_;

  TRACE_ADHOC and warn "<ch> moving $session to new parent $new_parent";

  confess "internal inconsistency" unless exists $kr_sessions{$session};
  confess "internal inconsistency" unless exists $kr_sessions{$new_parent};

  my $old_parent = $self->_data_ses_get_parent($session);

  confess "internal inconsistency" unless exists $kr_sessions{$old_parent};

  # Remove the session from its old parent.
  delete $kr_sessions{$old_parent}->[SS_CHILDREN]->{$session};
  $self->_data_ses_refcount_dec($old_parent);

  # Change the session's parent.
  $kr_sessions{$session}->[SS_PARENT] = $new_parent;

  # Add the current session to the new parent's children.
  $kr_sessions{$new_parent}->[SS_CHILDREN]->{$session} = $session;
  $self->_data_ses_refcount_inc($new_parent);
}

### Get a session's parent.

sub _data_ses_get_parent {
  my ($self, $session) = @_;
  confess "internal inconsistency" unless exists $kr_sessions{$session};
  return $kr_sessions{$session}->[SS_PARENT];
}

### Get a session's children.

sub _data_ses_get_children {
  my ($self, $session) = @_;
  confess "internal inconsistency" unless exists $kr_sessions{$session};
  return values %{$kr_sessions{$session}->[SS_CHILDREN]};
}

### Is a session a child of another?

sub _data_ses_is_child {
  my ($self, $parent, $child) = @_;
  confess "internal inconsistency" unless exists $kr_sessions{$parent};
  return exists $kr_sessions{$parent}->[SS_CHILDREN]->{$child};
}

### Determine whether a session exists.  We should only need to verify
### this for sessions provided by the outside.  Internally, our code
### should be so clean it's not necessary.

sub _data_ses_exists {
  my ($self, $session) = @_;
  return exists $kr_sessions{$session};
}

### Resolve a session into its reference.

sub _data_ses_resolve {
  my ($self, $session) = @_;
  return undef unless exists $kr_sessions{$session}; # Prevents autoviv.
  return $kr_sessions{$session}->[SS_SESSION];
}

### Resolve a session ID into its reference.

sub _data_ses_resolve_to_id {
  my ($self, $session) = @_;
  return undef unless exists $kr_sessions{$session}; # Prevents autoviv.
  return $kr_sessions{$session}->[SS_ID];
}

### Decrement a session's main reference count.  This is called by
### each watcher when the last thing it watches for the session goes
### away.  In other words, a session's reference count should only
### enumerate the different types of things being watched; not the
### number of each.

sub _data_ses_refcount_dec {
  my ($self, $session) = @_;

  TRACE_ADHOC and warn "<r-> decrementing refcount for $session";

  return unless exists $kr_sessions{$session};
  confess "internal inconsistency" unless exists $kr_sessions{$session};

  if (--$kr_sessions{$session}->[SS_REFCOUNT] < 0) {
    confess( $self->_data_alias_loggable($session),
             " reference count went below zero"
           );
  }
}

### Increment a session's main reference count.

sub _data_ses_refcount_inc {
  my ($self, $session) = @_;
  TRACE_ADHOC and warn "<r-> decrementing refcount for $session";
  confess "incrementing refcount for nonexistent session"
    unless exists $kr_sessions{$session};
  $kr_sessions{$session}->[SS_REFCOUNT]++;
}

### Determine whether a session is ready to be garbage collected.
### Free the session if it is.

sub _data_ses_collect_garbage {
  my ($self, $session) = @_;

  TRACE_ADHOC and warn "<gc> collecting garbage for $session";

  # The next line is necessary for some strange reason.  This feels
  # like a kludge, but I'm currently not smart enough to figure out
  # what it's working around.

  confess "internal inconsistency" unless exists $kr_sessions{$session};

  if (TRACE_GARBAGE) {
    my $ss = $kr_sessions{$session};
    warn( "<gc> +----- GC test for ", $self->_data_alias_loggable($session),
          " ($session) -----\n",
          "<gc> | total refcnt  : $ss->[SS_REFCOUNT]\n",
          "<gc> | event count   : ",
          $self->_data_ev_get_count_to($session), "\n",
          "<gc> | post count    : ",
          $self->_data_ev_get_count_from($session), "\n",
          "<gc> | child sessions: ",
          scalar(keys(%{$ss->[SS_CHILDREN]})), "\n",
          "<gc> | handles in use: ",
          $self->_data_handle_count_ses($session), "\n",
          "<gc> | aliases in use: ",
          $self->_data_alias_count_ses($session), "\n",
          "<gc> | extra refs    : ",
          $self->_data_extref_count_ses($session), "\n",
          "<gc> +---------------------------------------------------\n",
        );
    unless ($ss->[SS_REFCOUNT]) {
      warn( "<gc> | ", $self->_data_alias_loggable($session),
            " is garbage; stopping it...\n",
            "<gc> +---------------------------------------------------\n",
          );
    }
  }

  if (ASSERT_GARBAGE) {
    my $ss = $kr_sessions{$session};
    my $calc_ref =
      ( $self->_data_ev_get_count_to($session) +
        $self->_data_ev_get_count_from($session) +
        scalar(keys(%{$ss->[SS_CHILDREN]})) +
        $self->_data_handle_count_ses($session) +
        $self->_data_extref_count_ses($session) +
        $self->_data_alias_count_ses($session)
      );

    # The calculated reference count really ought to match the one
    # POE's been keeping track of all along.

    confess( $self->_data_alias_loggable($session),
             " has a reference count inconsistency",
             " (calc=$calc_ref; actual=$ss->[SS_REFCOUNT])\n"
           ) if $calc_ref != $ss->[SS_REFCOUNT];
  }

  return if $kr_sessions{$session}->[SS_REFCOUNT];

  $self->_data_ses_stop($session);
}

### Return the number of sessions we know about.

sub _data_ses_count {
  return scalar keys %kr_sessions;
}

### Close down a session by force.

# Dispatch _stop to a session, removing it from the kernel's data
# structures as a side effect.

sub _data_ses_stop {
  my ($self, $session) = @_;

  TRACE_GARBAGE and warn "<gc> stopping $session";

  confess unless exists $kr_sessions{$session};

  $self->_dispatch_event
    ( $session, $kr_active_session,
      EN_STOP, ET_STOP, [],
      __FILE__, __LINE__, time(), undef
    );
}

} # Close scope.

###############################################################################
###############################################################################
###############################################################################

#------------------------------------------------------------------------------
# Accessors: Uncategorized.

### Resolve $whatever into a session reference, trying every method we
### can until something succeeds.

sub _data_whatever_resolve {
  my ($self, $whatever) = @_;
  my $session;

  # Resolve against sessions.
  $session = $self->_data_ses_resolve($whatever);
  return $session if defined $session;

  # Resolve against IDs.
  $session = $self->_data_sid_resolve($whatever);
  return $session if defined $session;

  # Resolve against aliases.
  $session = $self->_data_alias_resolve($whatever);
  return $session if defined $session;

  # Resolve against the Kernel itself.  Use "eq" instead of "==" here
  # because $whatever is often a string.
  return $whatever if $whatever eq $self;

  # We don't know what it is.
  return undef;
}

### Test whether POE has become idle.

sub _data_test_for_idle_poe_kernel {
  my $self = shift;

  if (TRACE_REFCOUNT) {
    warn( "<rc> ,----- Kernel Activity -----\n",
          "<rc> | Events : ", $kr_queue->get_item_count(), "\n",
          "<rc> | Files  : ", $self->_data_handle_count(), "\n",
          "<rc> | Extra  : ", $self->_data_extref_count(), "\n",
          "<rc> | Procs  : $kr_child_procs\n",
          "<rc> `---------------------------\n",
          "<rc> ..."
         );
  }

  unless ( $kr_queue->get_item_count() > 1 or  # > 1 for signal poll loop
           $self->_data_handle_count() or
           $self->_data_extref_count() or
           $kr_child_procs
         ) {

    $self->_data_ev_enqueue
      ( $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'IDLE' ],
        __FILE__, __LINE__, time(),
      ) if $self->_data_ses_count();
  }
}


###############################################################################
# Helpers.

### Explain why a session could not be resolved.

sub explain_resolve_failure {
  my ($self, $whatever) = @_;
  local $Carp::CarpLevel = 2;

  confess "Cannot resolve ``$whatever'' into a session reference\n"
    if ASSERT_SESSIONS;

  $! = ESRCH;
  TRACE_RETURNS  and carp  "session not resolved: $!";
  ASSERT_RETURNS and confess "session not resolved: $!";
}

### Explain why a function is returning unsuccessfully.

sub explain_return {
  my $message = shift;
  local $Carp::CarpLevel = 2;
  ASSERT_RETURNS and confess $message;
  TRACE_RETURNS  and carp  $message;
}

### Explain how the user made a mistake calling a function.

sub explain_usage {
  my $message = shift;
  local $Carp::CarpLevel = 2;
  ASSERT_USAGE   and confess $message;
  ASSERT_RETURNS and confess $message;
  TRACE_RETURNS  and carp  $message;
}

#==============================================================================
# SIGNALS
#==============================================================================

#------------------------------------------------------------------------------
# Register or remove signals.

# Public interface for adding or removing signal handlers.

sub sig {
  my ($self, $signal, $event_name) = @_;

  ASSERT_USAGE and do {
    confess "undefined signal in sig()" unless defined $signal;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved assigning it to a signal"
        ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  if (defined $event_name) {
    $self->_data_sig_add($kr_active_session, $signal, $event_name);
  }
  else {
    $self->_data_sig_remove($kr_active_session, $signal);
  }
}

# Public interface for posting signal events.

sub signal {
  my ($self, $destination, $signal, @etc) = @_;

  ASSERT_USAGE and do {
    confess "undefined destination in signal()" unless defined $destination;
    confess "undefined signal in signal()" unless defined $signal;
  };

  my $session = $self->_data_whatever_resolve($destination);
  unless (defined $session) {
    $self->explain_resolve_failure($destination);
    return;
  }

  $self->_data_ev_enqueue
    ( $session, $kr_active_session,
      EN_SIGNAL, ET_SIGNAL, [ $signal, @etc ],
      (caller)[1,2], time(),
    );
}

# Public interface for flagging signals as handled.  This will replace
# the handlers' return values as an implicit flag.  Returns undef so
# it may be used as the last function in an event handler.

sub sig_handled {
  my $self = shift;
  $self->_data_sig_handled();
}

# Attach a window or widget's destroy/closure to the UIDESTROY signal.

sub signal_ui_destroy {
  my ($self, $window) = @_;
  $self->loop_attach_uidestroy($window);
}


#==============================================================================
# KERNEL
#==============================================================================

sub new {
  my $type = shift;

  # Prevent multiple instances, no matter how many times it's called.
  # This is a backward-compatibility enhancement for programs that
  # have used versions prior to 0.06.  It also provides a convenient
  # single entry point into the entirety of POE's state: point a
  # Dumper module at it, and you'll see a hideous tree of knowledge.
  # Be careful, though.  Its apples bite back.
  unless (defined $poe_kernel) {

    # Create our master queue.
    $kr_queue = POE::Queue::Array->new();

    my $self = $poe_kernel = bless
      [ undef,               # KR_SESSIONS
        undef,               # KR_FILENOS
        undef,               # KR_SIGNALS
        undef,               # KR_ALIASES
        \$kr_active_session, # KR_ACTIVE_SESSION
        \$kr_queue,          # KR_QUEUE
        undef,               # KR_ID
        undef,               # KR_SESSION_IDS
        undef,               # KR_SID_SEQ
      ], $type;

    # Kernel ID, based on Philip Gwyn's code.  I hope he still can
    # recognize it.  KR_SESSION_IDS is a hash because it will almost
    # always be sparse.  This goes before signals are registered
    # because it sometimes spawns /bin/hostname or the equivalent,
    # generating spurious CHLD signals before the Kernel is fully
    # initialized.

    my $hostname = eval { (POSIX::uname)[1] };
    $hostname = hostname() unless defined $hostname;

    $self->[KR_ID] = $hostname . '-' .  unpack('H*', pack('N*', time, $$));
    $self->_data_sid_set($self->[KR_ID], $self);

    # Start the Kernel's session.
    $self->_initialize_kernel_session();
    $self->_initialize_kernel_signals();
  }

  # Return the global instance.
  $poe_kernel;
}

#------------------------------------------------------------------------------
# Send an event to a session right now.  Used by _disp_select to
# expedite select() events, and used by run() to deliver posted events
# from the queue.

# This is for collecting event frequencies if TRACE_PROFILE is enabled.
my %profile;

# Dispatch an event to its session.  A lot of work goes on here.

sub _dispatch_event {
  my ( $self,
       $session, $source_session, $event, $type, $etc, $file, $line,
       $time, $seq
     ) = @_;

  ASSERT_ADHOC and do {
    confess "<ev> undefined dest session" unless defined $session;
    confess "<ev> undefined source session" unless defined $source_session;
  };

  TRACE_ADHOC and
    warn( "<ev> Dispatching event $seq ``$event'' (@$etc) ",
          "from $source_session to $session"
        );

  my $local_event = $event;

  if (TRACE_PROFILE) {
    $profile{$event}++;
  }

  # Pre-dispatch processing.

  unless ($type & (ET_USER | ET_CALL)) {

    # The _start event is dispatched immediately as part of allocating
    # a session.  Set up the kernel's tables for this session.

    if ($type & ET_START) {
      my $sid = $self->_data_sid_allocate();
      $self->_data_ses_allocate($session, $sid, $source_session);
    }

    # A "select" event has just come out of the queue.  Reset its
    # actual state to its requested state before handling the event.

    elsif ($type & ET_SELECT) {
      $self->_data_handle_resume_requested_state(@$etc);
    }

    # Some sessions don't do anything in _start and expect their
    # creators to provide a start-up event.  This means we can't
    # &_collect_garbage at _start time.  Instead, we post a
    # garbage-collect event at start time, and &_collect_garbage at
    # delivery time.  This gives the session's creator time to do
    # things with it before we reap it.

    elsif ($type & ET_GC) {
      $self->_data_ses_collect_garbage($session);
      return 0;
    }

    # A session's about to stop.  Notify its parents and children of
    # the impending change in their relationships.  Incidental _stop
    # events are handled before the dispatch.

    elsif ($type & ET_STOP) {

      # Tell child sessions that they have a new parent (the departing
      # session's parent).  Tell the departing session's parent that
      # it has new child sessions.

      my $parent = $self->_data_ses_get_parent($session);

      foreach my $child ($self->_data_ses_get_children($session)) {
        $self->_dispatch_event
          ( $parent, $self,
            EN_CHILD, ET_CHILD, [ CHILD_GAIN, $child ],
            $file, $line, time(), undef
          );
        $self->_dispatch_event
          ( $child, $self,
            EN_PARENT, ET_PARENT,
            [ $self->_data_ses_get_parent($child), $parent, ],
            $file, $line, time(), undef
          );
      }

      # Tell the departing session's parent that the departing session
      # is departing.

      if (defined $parent) {
        $self->_dispatch_event
          ( $parent, $self,
            EN_CHILD, ET_CHILD, [ CHILD_LOSE, $session ],
            $file, $line, time(), undef
          );
      }
    }

    # Preprocess signals.  This is where _signal is translated into
    # its registered handler's event name, if there is one.

    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];

      TRACE_SIGNALS and
        warn( "<sg> dispatching ET_SIGNAL ($signal) to session ",
              $session->ID, "\n"
            );

      # Step 0: Reset per-signal structures.

      $self->_data_sig_reset_handled($signal);

      # Step 1: Propagate the signal to sessions that are watching it.

      if ($self->_data_sig_explicitly_watched($signal)) {
        while (my ($session, $event) = $self->_data_sig_watchers($signal)) {
          my $session_ref = $self->_data_ses_resolve($session);

          TRACE_SIGNALS and
            warn( "<sg> propagating explicit signal $event ($signal) ",
                  "to session ", $session_ref->ID, "\n"
                );

          $self->_dispatch_event
            ( $session_ref, $self,
              $event, ET_SIGNAL_EXPLICIT, $etc,
              $file, $line, time(), undef
            );
        }
      }
    }

    # Step 2: Propagate the signal to this session's children.  This
    # happens first, making the signal's traversal through the
    # parent/child tree depth first.  It ensures that signals posted
    # to the Kernel are delivered to the Kernel last.

    if ($type & (ET_SIGNAL | ET_SIGNAL_COMPATIBLE)) {
      my $signal = $etc->[0];
      foreach ($self->_data_ses_get_children($session)) {

        TRACE_SIGNALS and
          warn( "<sg> propagating compatible signal ($signal) to session ",
                $_->ID, "\n"
              );

        $self->_dispatch_event
          ( $_, $self,
            $event, ET_SIGNAL_COMPATIBLE, $etc,
            $file, $line, time(), undef
          );

        TRACE_SIGNALS and warn "<sg> propagated to $_ (", $_->ID, ")";
      }

      # If this session already received a signal in step 1, then
      # ignore dispatching it again in this step.
      return if ( ($type & ET_SIGNAL_COMPATIBLE) and
                  $self->_data_sig_watched_by_session($signal, $session)
                );
    }
  }

  # The destination session doesn't exist.  This indicates sloppy
  # programming, possibly within POE::Kernel.

  unless ($self->_data_ses_exists($session)) {
    warn( "<ev> discarding event $seq ``$event'' to nonexistent ",
          $self->_data_alias_loggable($session), "\n"
        ) if TRACE_EVENTS;
    return;
  }

  if (TRACE_EVENTS) {
    warn( "<ev> dispatching event $seq ``$event'' to $session ",
          $self->_data_alias_loggable($session)
        );
    if ($event eq EN_SIGNAL) {
      warn "<ev>     signal($etc->[0])\n";
    }
  }

  # Prepare to call the appropriate handler.  Push the current active
  # session on Perl's call stack.
  my $hold_active_session = $kr_active_session;
  $kr_active_session = $session;

  # Clear the implicit/explicit signal handler flags for this event
  # dispatch.  We'll use them afterward to carp at the user if they
  # handled something implicitly but not explicitly.

  $self->_data_sig_clear_handled_flags();

  # Dispatch the event, at long last.
  my $return =
    $session->_invoke_state($source_session, $event, $etc, $file, $line);

  # Stringify the handler's return value if it belongs in the POE
  # namespace.  $return's scope exists beyond the post-dispatch
  # processing, which includes POE's garbage collection.  The scope
  # bleed was known to break determinism in surprising ways.

  if (defined $return) {
    $return = "$return" if substr(ref($return), 0, 5) eq 'POE::';
  }
  else {
    $return = '';
  }

  # Pop the active session, now that it's not active anymore.
  $kr_active_session = $hold_active_session;

  if (TRACE_EVENTS) {
    warn( "<ev> event $seq ``$event'' returns ($return)\n"
        );
  }

  # Post-dispatch processing.  This is a user event (but not a call),
  # so garbage collect it.  Also garbage collect the sender.

  if ($type & ET_USER) {
    $self->_data_ses_collect_garbage($session);
    #$self->_data_ses_collect_garbage($source_session);
  }

  # A new session has started.  Tell its parent.  Incidental _start
  # events are fired after the dispatch.  Garbage collection is
  # delayed until ET_GC.

  if ($type & ET_START) {
    $self->_dispatch_event
      ( $self->_data_ses_get_parent($session), $self,
        EN_CHILD, ET_CHILD, [ CHILD_CREATE, $session, $return ],
        $file, $line, time(), undef
      );
  }

  # This session has stopped.  Clean up after it.  There's no
  # garbage collection necessary since the session's stopped.

  elsif ($type & ET_STOP) {
    $self->_data_ses_free($session);
  }

  # Step 3: Check for death by terminal signal.

  elsif ($type & (ET_SIGNAL | ET_SIGNAL_EXPLICIT | ET_SIGNAL_COMPATIBLE)) {
    $self->_data_sig_touched_session($session);

    if ($type & ET_SIGNAL) {
      $self->_data_sig_free_terminated_sessions();
    }
  }

  # It's an alarm being dispatched.

  elsif ($type & ET_ALARM) {
    $self->_data_ses_collect_garbage($session);
  }

  # It's a select being dispatched.
  elsif ($type & ET_SELECT) {
    $self->_data_ses_collect_garbage($session);
  }

  # Return what the handler did.  This is used for call().
  $return;
}

#------------------------------------------------------------------------------
# POE's main loop!  Now with Tk and Event support!

# Do pre-run startup.  Initialize the event loop, and allocate a
# session structure to represent the Kernel.

sub _initialize_kernel_session {
  my $self = shift;

  $self->loop_initialize($self);

  $kr_active_session = $self;
  $self->_data_ses_allocate($self, $self->[KR_ID], undef);
}

# Regsiter all known signal handlers, except the troublesome ones.
# "Troublesome" signals are the ones which aren't really signals, are
# uncatchable, are improperly implemented on a given platform, or are
# already being handled by the runtime environment.

sub _initialize_kernel_signals {
  my $self = shift;

  foreach my $signal (keys(%SIG)) {

    # Nonexistent signals, and ones which are globally unhandled.
    next if ($signal =~ /^( NUM\d+
                            |__[A-Z0-9]+__
                            |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE
                            |RTMIN|RTMAX|SETS
                            |SEGV
                            |
                          )$/x
            );

    # Windows doesn't have a SIGBUS, but the debugger causes SIGBUS to
    # be entered into %SIG.  It's fatal to register its handler.
    next if $signal eq 'BUS' and RUNNING_IN_HELL;

    # Apache uses SIGCHLD and/or SIGCLD itself, so we can't.
    next if $signal =~ /^CH?LD$/ and exists $INC{'Apache.pm'};

    # The signal is good.  Register a handler for it with the loop.
    $self->loop_watch_signal($signal);
  }
}

# Do post-run cleanup.

sub finalize_kernel {
  my $self = shift;

  # Disable signal watching since there's now no place for them to go.
  foreach my $signal (keys %SIG) {
    $self->loop_ignore_signal($signal);
  }

  # The main loop is done, no matter which event library ran it.
  $self->loop_finalize();

  if (TRACE_PROFILE) {
    print STDERR ',----- Event Profile ' , ('-' x 53), ",\n";
    foreach (sort keys %profile) {
      printf STDERR "| %60.60s %10d |\n", $_, $profile{$_};
    }
    print STDERR '`', ('-' x 73), "'\n";
  }
}

sub run_one_timeslice {
  my $self = shift;
  return undef unless $self->_data_ses_count();
  $self->loop_do_timeslice();
  unless ($self->_data_ses_count()) {
    $self->finalize_kernel();
    $kr_run_warning |= KR_RUN_DONE;
  }
}

sub run {
  # So run() can be called as a class method.
  my $self = $poe_kernel;

  # Flag that run() was called.
  $kr_run_warning |= KR_RUN_CALLED;

  $self->loop_run();

  # Clean up afterwards.
  $self->finalize_kernel();
  $kr_run_warning |= KR_RUN_DONE;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  # Warn that a session never had the opportunity to run if one was
  # created but run() was never called.

  unless ($kr_run_warning & KR_RUN_CALLED) {
    warn "POE::Kernel's run() method was never called.\n"
      if $kr_run_warning & KR_RUN_SESSION;
  }
}

#------------------------------------------------------------------------------
# _invoke_state is what _dispatch_event calls to dispatch a transition
# event.  This is the kernel's _invoke_state so it can receive events.
# These are mostly signals, which are propagated down in
# _dispatch_event.

sub _invoke_state {
  my ($self, $source_session, $event, $etc) = @_;

  # This is an event loop to poll for child processes without needing
  # to catch SIGCHLD.

  if ($event eq EN_SCPOLL) {

    TRACE_SIGNALS and
      warn "POE::Kernel is polling for signals at " . time() . "\n";

    # Reap children for as long as waitpid(2) says something
    # interesting has happened.  -><- This has a strong possibility of
    # an infinite loop.

    my $pid;
    while ($pid = waitpid(-1, WNOHANG)) {

      # waitpid(2) returned a process ID.  Emit an appropriate SIGCHLD
      # event and loop around again.

      if ((RUNNING_IN_HELL and $pid < -1) or ($pid > 0)) {
        if (RUNNING_IN_HELL or WIFEXITED($?) or WIFSIGNALED($?)) {

          TRACE_SIGNALS and
            warn "POE::Kernel detected SIGCHLD (pid=$pid; exit=$?)\n";

          $self->_data_ev_enqueue
            ( $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'CHLD', $pid, $? ],
              __FILE__, __LINE__, time(),
            );
        }
        else {
          TRACE_SIGNALS and
            warn "POE::Kernel detected strange exit (pid=$pid; exit=$?\n";
        }

        TRACE_SIGNALS and warn "POE::Kernel will poll again immediately.\n";

        next;
      }

      # The only other negative value waitpid(2) should return is -1.

      confess "internal consistency error: waitpid returned $pid"
        if $pid != -1;

      # If the error is an interrupted syscall, poll again right away.

      if ($! == EINTR) {
        TRACE_SIGNALS and
          warn( "POE::Kernel's waitpid(2) was interrupted.\n",
                "POE::Kernel will poll again immediately.\n"
              );
        next;
      }

      # No child processes exist.  -><- This is different than
      # children being present but running.  Maybe this condition
      # could halt polling entirely, and some UNIVERSAL::fork wrapper
      # could restart polling when processes are forked.

      if ($! == ECHILD) {
        TRACE_SIGNALS and warn "POE::Kernel has no child processes.\n";
        last;
      }

      # Some other error occurred.

      TRACE_SIGNALS and warn "POE::Kernel's waitpid(2) got error: $!\n";
      last;
    }

    # If waitpid() returned 0, then we have child processes.

    $kr_child_procs = !$pid;

    # The poll loop is over.  Resume slowly polling for signals.

    TRACE_SIGNALS and warn "POE::Kernel will poll again after a delay.\n";

    $self->_data_ev_enqueue
      ( $self, $self, EN_SCPOLL, ET_SCPOLL, [ ],
        __FILE__, __LINE__, time() + 1
      ) if $self->_data_ses_count() > 1;
  }

  # A signal was posted.  Because signals propagate depth-first, this
  # _invoke_state is called last in the dispatch.  If the signal was
  # SIGIDLE, then post a SIGZOMBIE if the main queue is still idle.

  elsif ($event eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless ($kr_queue->get_item_count() > 1 or $self->_data_handle_count()) {
        $self->_data_ev_enqueue
          ( $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'ZOMBIE' ],
            __FILE__, __LINE__, time(),
          );
      }
    }
  }

  return 0;
}

#==============================================================================
# SESSIONS
#==============================================================================

# Dispatch _start to a session, allocating it in the kernel's data
# structures as a side effect.

sub session_alloc {
  my ($self, $session, @args) = @_;

  # If we already returned, then we must reinitialize.  This is so
  # $poe_kernel->run() will work correctly more than once.
  if ($kr_run_warning & KR_RUN_DONE) {
    $kr_run_warning &= ~KR_RUN_DONE;
    $self->_initialize_kernel_session();
    $self->_initialize_kernel_signals();
  }

  confess $self->_data_alias_loggable($session), " already exists\a"
    if ASSERT_RELATIONS and $self->_data_ses_exists($session);

  # Register that a session was created.
  $kr_run_warning |= KR_RUN_SESSION;

  $self->_dispatch_event
    ( $session, $kr_active_session,
      EN_START, ET_START, \@args,
      __FILE__, __LINE__, time(), undef
    );
  $self->_data_ev_enqueue
    ( $session, $kr_active_session, EN_GC, ET_GC, [],
      __FILE__, __LINE__, time(),
    );
}

# Detach a session from its parent.  This breaks the parent/child
# relationship between the current session and its parent.  Basically,
# the current session is given to the Kernel session.  Unlike with
# _stop, the current session's children follow their parent.

sub detach_myself {
  my $self = shift;

  # Can't detach from the kernel.
  if ($self->_data_ses_get_parent($kr_active_session) == $self) {
    $! = EPERM;
    return;
  }

  my $old_parent = $self->_data_ses_get_parent($kr_active_session);

  # Tell the old parent session that the child is departing.
  $self->_dispatch_event
    ( $old_parent, $self,
      EN_CHILD, ET_CHILD, [ CHILD_LOSE, $kr_active_session ],
      (caller)[1,2], time(), undef
    );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the current session that its parentage is changing.
  $self->_dispatch_event
    ( $kr_active_session, $self,
      EN_PARENT, ET_PARENT, [ $old_parent, $self ],
      (caller)[1,2], time(), undef
    );

  $self->_data_ses_move_child($kr_active_session, $self);

  # Success!
  return 1;
}

# Detach a child from this, the parent.  The session being detached
# must be a child of the current session.

sub detach_child {
  my ($self, $child) = @_;

  my $child_session = $self->_data_whatever_resolve($child);
  unless (defined $child_session) {
    $self->explain_resolve_failure($child);
    return;
  }

  # Can't detach if it belongs to the kernel.  -><- We shouldn't need
  # to check for this.
  if ($kr_active_session == $self) {
    $! = EPERM;
    return;
  }

  # Can't detach if it's not a child of the current session.
  unless ($self->_data_ses_is_child($kr_active_session, $child_session)) {
    $! = EPERM;
    return;
  }

  # Tell the current session that the child is departing.
  $self->_dispatch_event
    ( $kr_active_session, $self,
      EN_CHILD, ET_CHILD, [ CHILD_LOSE, $child_session ],
      (caller)[1,2], time(), undef
    );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the child session that its parentage is changing.
  $self->_dispatch_event
    ( $child_session, $self,
      EN_PARENT, ET_PARENT, [ $kr_active_session, $self ],
      (caller)[1,2], time(), undef
    );

  $self->_data_ses_move_child($child_session, $self);

  # Success!
  return 1;
}

### Helpful accessors.  -><- Most of these are not documented.

sub get_active_session {
  return $kr_active_session;
}

sub get_event_count {
  return $kr_queue->get_item_count();
}

sub get_next_event_time {
  return $kr_queue->get_next_priority();
}

#==============================================================================
# EVENTS
#==============================================================================

#------------------------------------------------------------------------------
# Post an event to the queue.

sub post {
  my ($self, $destination, $event_name, @etc) = @_;

  ASSERT_USAGE and do {
    confess "destination is undefined in post()" unless defined $destination;
    confess "event is undefined in post()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by posting it"
        ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = $self->_data_whatever_resolve($destination);
  unless (defined $session) {
    $self->explain_resolve_failure($destination);
    return;
  }

  # Enqueue the event for "now", which simulates FIFO in our
  # time-ordered queue.

  $self->_data_ev_enqueue
    ( $session, $kr_active_session, $event_name, ET_USER, \@etc,
      (caller)[1,2], time(),
    );
  return 1;
}

#------------------------------------------------------------------------------
# Post an event to the queue for the current session.

sub yield {
  my ($self, $event_name, @etc) = @_;

  ASSERT_USAGE and do {
    confess "event name is undefined in yield()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by yielding it"
        ) if exists $poes_own_events{$event_name};
  };

  $self->_data_ev_enqueue
    ( $kr_active_session, $kr_active_session, $event_name, ET_USER, \@etc,
      (caller)[1,2], time(),
    );

  undef;
}

#------------------------------------------------------------------------------
# Call an event handler directly.

sub call {
  my ($self, $destination, $event_name, @etc) = @_;

  ASSERT_USAGE and do {
    confess "destination is undefined in call()" unless defined $destination;
    confess "event is undefined in call()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by calling it"
        ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = $self->_data_whatever_resolve($destination);
  unless (defined $session) {
    $self->explain_resolve_failure($destination);
    return;
  }

  # Dispatch the event right now, bypassing the queue altogether.
  # This tends to be a Bad Thing to Do.

  # -><- The difference between synchronous and asynchronous events
  # should be made more clear in the documentation, so that people
  # have a tendency not to abuse them.  I discovered in xws that that
  # mixing the two types makes it harder than necessary to write
  # deterministic programs, but the difficulty can be ameliorated if
  # programmers set some base rules and stick to them.

  my $return_value =
    $self->_dispatch_event
      ( $session, $kr_active_session,
        $event_name, ET_CALL, \@etc,
        (caller)[1,2], time(), undef
      );
  $! = 0;
  return $return_value;
}

#------------------------------------------------------------------------------
# Peek at pending alarms.  Returns a list of pending alarms.  This
# function is deprecated; its lack of documentation is by design.
# Here's the old POD, in case you're interested.
#
# # Return the names of pending timed events.
# @event_names = $kernel->queue_peek_alarms( );
#
# =item queue_peek_alarms
#
# queue_peek_alarms() returns a time-ordered list of event names from
# the current session that have pending timed events.  If a event
# handler has more than one pending timed event, it will be listed
# that many times.
#
#   my @pending_timed_events = $kernel->queue_peek_alarms();

sub queue_peek_alarms {
  my $self = shift;

  my $alarm_count = $self->_data_ev_get_count_to($kr_active_session);

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION] == $kr_active_session;
    return 1;
  };

  return( map { $_->[ITEM_PAYLOAD]->[EV_NAME] }
          $kr_queue->peek_items($my_alarm, $alarm_count)
        );
}

#==============================================================================
# DELAYED EVENTS
#==============================================================================

sub alarm {
  my ($self, $event_name, $time, @etc) = @_;

  ASSERT_USAGE and do {
    confess "event name is undefined in alarm()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting an alarm for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name) {
    $self->explain_return("invalid parameter to alarm() call");
    return EINVAL;
  }

  $self->_data_ev_clear_alarm_by_name($kr_active_session, $event_name);

  # Add the new alarm if it includes a time.  Calling _data_ev_enqueue
  # directly is faster than calling alarm_set to enqueue it.
  if (defined $time) {
    $self->_data_ev_enqueue
      ( $kr_active_session, $kr_active_session,
        $event_name, ET_ALARM, [ @etc ],
        (caller)[1,2], $time,
      );
  }
  else {
    # The event queue has become empty?  Stop the time watcher.
    $self->loop_pause_time_watcher() unless $kr_queue->get_item_count();
  }

  return 0;
}

# Add an alarm without clobbering previous alarms of the same name.
sub alarm_add {
  my ($self, $event_name, $time, @etc) = @_;

  ASSERT_USAGE and do {
    confess "undefined event name in alarm_add()" unless defined $event_name;
    confess "undefined time in alarm_add()" unless defined $time;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by adding an alarm for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name and defined $time) {
    $self->explain_return("invalid parameter to alarm_add() call");
    return EINVAL;
  }

  $self->_data_ev_enqueue
    ( $kr_active_session, $kr_active_session,
      $event_name, ET_ALARM, [ @etc ],
      (caller)[1,2], $time,
    );

  return 0;
}

# Add a delay, which is just an alarm relative to the current time.
sub delay {
  my ($self, $event_name, $delay, @etc) = @_;

  ASSERT_USAGE and do {
    confess "undefined event name in delay()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a delay for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name) {
    $self->explain_return("invalid parameter to delay() call");
    return EINVAL;
  }

  if (defined $delay) {
    $self->alarm($event_name, time() + $delay, @etc);
  }
  else {
    $self->alarm($event_name);
  }

  return 0;
}

# Add a delay without clobbering previous delays of the same name.
sub delay_add {
  my ($self, $event_name, $delay, @etc) = @_;

  ASSERT_USAGE and do {
    confess "undefined event name in delay_add()" unless defined $event_name;
    confess "undefined time in delay_add()" unless defined $delay;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by adding a delay for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name and defined $delay) {
    $self->explain_return("invalid parameter to delay_add() call");
    return EINVAL;
  }

  $self->alarm_add($event_name, time() + $delay, @etc);

  return 0;
}

#------------------------------------------------------------------------------
# New style alarms.

# Set an alarm.  This does more *and* less than plain alarm().  It
# only sets alarms (that's the less part), but it also returns an
# alarm ID (that's the more part).

sub alarm_set {
  my ($self, $event_name, $time, @etc) = @_;

  unless (defined $event_name) {
    $self->explain_usage("undefined event name in alarm_set()");
    $! = EINVAL;
    return;
  }

  unless (defined $time) {
    $self->explain_usage("undefined time in alarm_set()");
    $! = EINVAL;
    return;
  }

  if (ASSERT_USAGE) {
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting an alarm for it"
        ) if exists $poes_own_events{$event_name};
  }

  return $self->_data_ev_enqueue
    ( $kr_active_session, $kr_active_session, $event_name, ET_ALARM, [ @etc ],
      (caller)[1,2], $time,
    );
}

# Remove an alarm by its ID.  -><- Now that alarms and events have
# been recombined, this will remove an event by its ID.  However,
# nothing returns an event ID, so nobody knows what to remove.

sub alarm_remove {
  my ($self, $alarm_id) = @_;

  unless (defined $alarm_id) {
    $self->explain_usage("undefined alarm id in alarm_remove()");
    $! = EINVAL;
    return;
  }

  my ($time, $event) =
    $self->_data_ev_clear_alarm_by_id($kr_active_session, $alarm_id);
  return unless defined $time;

  # In a list context, return the alarm that was removed.  In a scalar
  # context, return a reference to the alarm that was removed.  In a
  # void context, return nothing.  Either way this returns a defined
  # value when someone needs something useful from it.

  return unless defined wantarray;
  return ( $event->[EV_NAME], $time, @{$event->[EV_ARGS]} ) if wantarray;
  return [ $event->[EV_NAME], $time, @{$event->[EV_ARGS]} ];
}

# Move an alarm to a new time.  This virtually removes the alarm and
# re-adds it somewhere else.

sub alarm_adjust {
  my ($self, $alarm_id, $delta) = @_;

  unless (defined $alarm_id) {
    $self->explain_usage("undefined alarm id in alarm_adjust()");
    $! = EINVAL;
    return;
  }

  unless (defined $delta) {
    $self->explain_usage("undefined alarm delta in alarm_adjust()");
    $! = EINVAL;
    return;
  }

  my $my_alarm = sub {
    $_[0]->[EV_SESSION] == $kr_active_session;
  };
  return $kr_queue->adjust_priority($alarm_id, $my_alarm, $delta);
}

# A convenient function for setting alarms relative to now.  It also
# uses whichever time() POE::Kernel can find, which may be
# Time::HiRes'.

sub delay_set {
  my ($self, $event_name, $seconds, @etc) = @_;

  unless (defined $event_name) {
    $self->explain_usage("undefined event name in delay_set()");
    $! = EINVAL;
    return;
  }

  if (ASSERT_USAGE) {
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a delay for it"
        ) if exists $poes_own_events{$event_name};
  }

  unless (defined $seconds) {
    $self->explain_usage("undefined seconds in delay_set()");
    $! = EINVAL;
    return;
  }

  return $self->_data_ev_enqueue
    ( $kr_active_session, $kr_active_session, $event_name, ET_ALARM, [ @etc ],
      (caller)[1,2], time() + $seconds,
    );
}

# Remove all alarms for the current session.

sub alarm_remove_all {
  my $self = shift;

  # This should never happen, actually.
  confess "unknown session in alarm_remove_all call"
    unless $self->_data_ses_exists($kr_active_session);

  # Free every alarm owned by the session.  This code is ripped off
  # from the _stop code to flush everything.

  my @removed = $self->_data_ev_clear_alarm_by_session($kr_active_session);

  return unless defined wantarray;
  return @removed if wantarray;
  return \@removed;
}

#==============================================================================
# SELECTS
#==============================================================================

sub _internal_select {
  my ($self, $session, $handle, $event_name, $mode) = @_;

  # If an event is included, then we're defining a filehandle watcher.

  if ($event_name) {
    $self->_data_handle_add($handle, $mode, $session, $event_name);
  }
  else {
    $self->_data_handle_remove($handle, $mode, $session);
  }
}

# A higher-level select() that manipulates read, write and expedite
# selects together.

sub select {
  my ($self, $handle, $event_r, $event_w, $event_e) = @_;

  if (ASSERT_USAGE) {
    confess "undefined filehandle in select()" unless defined $handle;
    confess "invalid filehandle in select()" unless defined fileno($handle);
    foreach ($event_r, $event_w, $event_e) {
      next unless defined $_;
      carp( "The '$_' event is one of POE's own.  Its " .
            "effect cannot be achieved by setting a file watcher to it"
          ) if exists($poes_own_events{$_});
    }
  }

  $self->_internal_select($kr_active_session, $handle, $event_r, VEC_RD);
  $self->_internal_select($kr_active_session, $handle, $event_w, VEC_WR);
  $self->_internal_select($kr_active_session, $handle, $event_e, VEC_EX);
  return 0;
}

# Only manipulate the read select.
sub select_read {
  my ($self, $handle, $event_name) = @_;

  ASSERT_USAGE and do {
    confess "<sl> undefined filehandle in select_read()"
      unless defined $handle;
    confess "<sl> invalid filehandle in select_read()"
      unless defined fileno($handle);
    carp( "<sl> The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a file watcher to it"
        ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, VEC_RD);
  return 0;
}

# Only manipulate the write select.
sub select_write {
  my ($self, $handle, $event_name) = @_;

  ASSERT_USAGE and do {
    confess "undefined filehandle in select_write()" unless defined $handle;
    confess "invalid filehandle in select_write()"
      unless defined fileno($handle);
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a file watcher to it"
        ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, VEC_WR);
  return 0;
}

# Only manipulate the expedite select.
sub select_expedite {
  my ($self, $handle, $event_name) = @_;

  ASSERT_USAGE and do {
    confess "undefined filehandle in select_expedite()" unless defined $handle;
    confess "invalid filehandle in select_expedite()"
      unless defined fileno($handle);
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a file watcher to it"
        ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, VEC_EX);
  return 0;
}

# Turn off a handle's write mode bit without doing
# garbage-collection things.
sub select_pause_write {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    confess "undefined filehandle in select_pause_write()"
      unless defined $handle;
    confess "invalid filehandle in select_pause_write()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, VEC_WR);

  $self->_data_handle_pause($handle, VEC_WR);

  return 1;
}

# Turn on a handle's write mode bit without doing garbage-collection
# things.
sub select_resume_write {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    confess "undefined filehandle in select_resume_write()"
      unless defined $handle;
    confess "invalid filehandle in select_resume_write()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, VEC_WR);

  $self->_data_handle_resume($handle, VEC_WR);

  return 1;
}

# Turn off a handle's read mode bit without doing garbage-collection
# things.
sub select_pause_read {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    confess "undefined filehandle in select_pause_read()"
      unless defined $handle;
    confess "invalid filehandle in select_pause_read()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, VEC_RD);

  $self->_data_handle_pause($handle, VEC_RD);

  return 1;
}

# Turn on a handle's read mode bit without doing garbage-collection
# things.
sub select_resume_read {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    confess "undefined filehandle in select_resume_read()"
      unless defined $handle;
    confess "invalid filehandle in select_resume_read()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, VEC_RD);

  $self->_data_handle_resume($handle, VEC_RD);

  return 1;
}

#==============================================================================
# Aliases: These functions expose the internal alias accessors with
# extra fun parameter/return value checking.
#==============================================================================

### Set an alias in the current session.

sub alias_set {
  my ($self, $name) = @_;

  ASSERT_USAGE and do {
    confess "undefined alias in alias_set()" unless defined $name;
  };

  # Don't overwrite another session's alias.
  my $existing_session = $self->_data_alias_resolve($name);
  if (defined $existing_session) {
    if ($existing_session != $kr_active_session) {
      $self->explain_usage("alias '$name' is in use by another session");
      return EEXIST;
    }
    return 0;
  }

  $self->_data_alias_add($kr_active_session, $name);
  return 0;
}

### Remove an alias from the current session.

sub alias_remove {
  my ($self, $name) = @_;

  ASSERT_USAGE and do {
    confess "undefined alias in alias_remove()" unless defined $name;
  };

  my $existing_session = $self->_data_alias_resolve($name);

  unless (defined $existing_session) {
    $self->explain_usage("alias does not exist");
    return ESRCH;
  }

  if ($existing_session != $kr_active_session) {
    $self->explain_usage("alias does not belong to current session");
    return EPERM;
  }

  $self->_data_alias_remove($kr_active_session, $name);
  return 0;
}

### Resolve an alias into a session.

sub alias_resolve {
  my ($self, $name) = @_;

  ASSERT_USAGE and do {
    confess "undefined alias in alias_resolve()" unless defined $name;
  };

  my $session = $self->_data_whatever_resolve($name);
  unless (defined $session) {
    $self->explain_resolve_failure($name);
    return;
  }

  $session;
}

### List the aliases for a given session.

sub alias_list {
  my ($self, $search_session) = @_;
  my $session =
    $self->_data_whatever_resolve($search_session || $kr_active_session);

  unless (defined $session) {
    $self->explain_resolve_failure($search_session);
    return;
  }

  # Return whatever can be found.
  my @alias_list = $self->_data_alias_list($session);
  return wantarray() ? @alias_list : $alias_list[0];
}

#==============================================================================
# Kernel and Session IDs
#==============================================================================

# Return the Kernel's "unique" ID.  There's only so much uniqueness
# available; machines on separate private 10/8 networks may have
# identical kernel IDs.  The chances of a collision are vanishingly
# small.

sub ID {
  my $self = shift;
  $self->[KR_ID];
}

# Resolve an ID to a session reference.  This function is virtually
# moot now that _data_whatever_resolve does it too.  This explicit
# call will be faster, though, so it's kept for things that can
# benefit from it.

sub ID_id_to_session {
  my ($self, $id) = @_;

  ASSERT_USAGE and do {
    confess "undefined ID in ID_id_to_session()" unless defined $id;
  };

  my $session = $self->_data_sid_resolve($id);
  return $session if defined $session;

  $self->explain_return("ID does not exist");
  $! = ESRCH;
  return;
}

# Resolve a session reference to its corresponding ID.

sub ID_session_to_id {
  my ($self, $session) = @_;

  ASSERT_USAGE and do {
    confess "undefined session in ID_session_to_id()" unless defined $session;
  };

  my $id = $self->_data_ses_resolve_to_id($session);
  if (defined $id) {
    $! = 0;
    return $id;
  }

  $self->explain_return("session ($session) does not exist");
  $! = ESRCH;
  return;
}

#==============================================================================
# Extra reference counts, to keep sessions alive when things occur.
# They take session IDs because they may be called from resources at
# times where the session reference is otherwise unknown.
#==============================================================================

sub refcount_increment {
  my ($self, $session_id, $tag) = @_;

  ASSERT_USAGE and do {
    confess "undefined session ID in refcount_increment()"
      unless defined $session_id;
    confess "undefined reference count tag in refcount_increment()"
      unless defined $tag;
  };

  my $session = $self->ID_id_to_session($session_id);
  unless (defined $session) {
    $self->explain_return("session id $session_id does not exist");
    $! = ESRCH;
    return;
  }

  my $refcount = $self->_data_extref_inc($session, $tag);
  # trace it here
  return $refcount;
}

sub refcount_decrement {
  my ($self, $session_id, $tag) = @_;

  ASSERT_USAGE and do {
    confess "undefined session ID in refcount_decrement()"
      unless defined $session_id;
    confess "undefined reference count tag in refcount_decrement()"
      unless defined $tag;
  };

  my $session = $self->ID_id_to_session($session_id);
  unless (defined $session) {
    $self->explain_return("session id $session_id does not exist");
    $! = ESRCH;
    return;
  }

  my $refcount = $self->_data_extref_dec($session, $tag);
  # trace it here
  return $refcount;
}

#==============================================================================
# HANDLERS
#==============================================================================

# Add or remove event handlers from sessions.
sub state {
  my ($self, $event, $state_code, $state_alias) = @_;
  $state_alias = $event unless defined $state_alias;

  ASSERT_USAGE and do {
    confess "undefined event name in state()" unless defined $event;
  };

  if ( (ref($kr_active_session) ne '') &&
       (ref($kr_active_session) ne 'POE::Kernel')
  ) {
    $kr_active_session->register_state($event, $state_code, $state_alias);
    return 0;
  }

  # -><- A terminal signal (such as UIDESTROY) kills a session.  The
  # Kernel deallocates the session, which cascades destruction to its
  # HEAP.  That triggers a Wheel's destruction, which calls
  # $kernel->state() to remove a state from the session.  The session,
  # though, is already gone.  If TRACE_RETURNS and/or ASSERT_RETURNS
  # is set, this causes a warning or fatal error.

  $self->explain_return("session ($kr_active_session) does not exist");
  return ESRCH;
}

###############################################################################
# Bootstrap the kernel.  This is inherited from a time when multiple
# kernels could be present in the same Perl process.

POE::Kernel->new();

###############################################################################
1;

__END__

=head1 NAME

POE::Kernel - an event driven threaded application kernel in Perl

=head1 SYNOPSIS

POE comes with its own event loop, which is based on select() and
written entirely in Perl.  To use it, simply:

  use POE;

POE can adapt itself to work with other event loops and I/O multiplex
systems.  Currently it adapts to Gtk, Tk, Event.pm, or IO::Poll when
one of those modules is used before POE::Kernel.

  use Gtk;  # Or Tk, Event, or IO::Poll;
  use POE;

Methods to manage the process' global Kernel instance:

  # Retrieve the kernel's unique identifier.
  $kernel_id = $kernel->ID;

  # Run the event loop, only returning when it has no more sessions to
  # dispatch events to.  Supports two forms.
  $poe_kernel->run();
  POE::Kernel->run();

FIFO event methods:

  # Post an event to an arbitrary session.
  $kernel->post( $session, $event, @event_args );

  # Post an event back to the current session.
  $kernel->yield( $event, @event_args );

  # Call an event handler synchronously.  Bypasses POE's event queue
  # and returns the handler's return value.
  $handler_result = $kernel->call( $session, $event, @event_args );

Original alarm and delay methods:

  # Post an event which will be delivered at a given Unix epoch time.
  # This clears previous timed events with the same state name.
  $kernel->alarm( $event, $epoch_time, @event_args );

  # Post an additional alarm, leaving existing ones in the queue.
  $kernel->alarm_add( $event, $epoch_time, @event_args );

  # Post an event which will be delivered after a delay, specified in
  # seconds hence. This clears previous timed events with the same
  # name.
  $kernel->delay( $event, $seconds, @event_args );

  # Post an additional delay, leaving existing ones in the queue.
  $kernel->delay_add( $event, $seconds, @event_args );

June 2001 alarm and delay methods:

  # Post an event which will be delivered at a given Unix epoch
  # time. This does not clear previous events with the same name.
  $alarm_id = $kernel->alarm_set( $event, $epoch_time, @etc );

  # Post an event which will be delivered a number of seconds hence.
  # This does not clear previous events with the same name.
  $alarm_id = $kernel->delay_set( $event, $seconds_hence, @etc );

  # Adjust an existing alarm by a number of seconds.
  $kernel->alarm_adjust( $alarm_id, $number_of_seconds );

  # Remove a specific alarm, regardless whether it shares a name with
  # others.
  $kernel->alarm_remove( $alarm_id );

  # Remove all alarms for the current session.
  #kernel->alarm_remove_all( );

Symbolic name, or session alias methods:

  # Set an alias for the current session.
  $status = $kernel->alias_set( $alias );

  # Clear an alias for the current session:
  $status = $kernel->alias_remove( $alias );

  # Resolve an alias into a session reference.  Most POE::Kernel
  # methods do this for you.
  $session_reference = $kernel->alias_resolve( $alias );

  # Resolve a session ID to a session reference.  The alias_resolve
  # method does this as well, but this is faster.
  $session_reference = $kernel->ID_id_to_session( $session_id );

  # Return a session ID for a session reference.  It is functionally
  # equivalent to $session->ID.
  $session_id = $kernel->ID_session_to_id( $session_reference );

  # Return a list of aliases for a session (or the current one, by
  # default).
  @aliases = $kernel->alias_list( $session );

Filehandle watcher methods:

  # Watch for read readiness on a filehandle.
  $kernel->select_read( $file_handle, $event );

  # Stop watching a filehandle for read-readiness.
  $kernel->select_read( $file_handle );

  # Watch for write readiness on a filehandle.
  $kernel->select_write( $file_handle, $event );

  # Stop watching a filehandle for write-readiness.
  $kernel->select_write( $file_handle );

  # Pause and resume write readiness watching.  These have lower
  # overhead than full select_write() calls.
  $kernel->select_pause_write( $file_handle );
  $kernel->select_resume_write( $file_handle );

  # Pause and resume read readiness watching.  These have lower
  # overhead than full select_read() calls.
  $kernel->select_pause_read( $file_handle );
  $kernel->select_resume_read( $file_handle );

  # Watch for out-of-bound (expedited) read readiness on a filehandle.
  $kernel->select_expedite( $file_handle, $event );

  # Stop watching a filehandle for out-of-bound data.
  $kernel->select_expedite( $file_handle );

  # Set and/or clear a combination of selects in one call.
  $kernel->select( $file_handle,
                   $read_event,     # or undef to clear it
                   $write_event,    # or undef to clear it
                   $expedite_event, # or undef to clear it
                 );

Signal watcher and generator methods:

  # Watch for a signal, and generate an event when it arrives.
  $kernel->sig( $signal_name, $event );

  # Stop watching for a signal.
  $kernel->sig( $signal_name );

  # Handle a signal, preventing the program from terminating.
  $kernel->sig_handled();

  # Post a signal through POE rather than through the underlying OS.
  # This only works within the same process.
  $kernel->signal( $session, $signal_name );

State (event handler) management methods:

  # Remove an existing handler from the current Session.
  $kernel->state( $event_name );

  # Add a new inline handler, or replace an existing one.
  $kernel->state( $event_name, $code_reference );

  # Add a new object or package handler, or replace an existing
  # one. The object method will be the same as the eventname.
  $kernel->state( $event_name, $object_ref_or_package_name );

  # Add a new object or package handler, or replace an existing
  # one. The object method may be different from the event name.
  $kernel->state( $event_name, $object_ref_or_package_name, $method_name );

External reference count methods:

  # Increment a session's external reference count.
  $kernel->refcount_increment( $session_id, $refcount_name );

  # Decrement a session's external reference count.
  $kernel->refcount_decrement( $session_id, $refcount_name );

Kernel data accessors:

  # Return a reference to the currently active session, or to the
  # kernel if called outside any session.
  $session = $kernel->get_active_session();

Exported symbols:

  # A reference to the global POE::Kernel instance.
  $poe_kernel

  # Some graphical toolkits (Tk) require at least one active widget in
  # order to use their event loops.  POE allocates a main window so it
  # can function when using one of these toolkits.
  $poe_main_window

=head1 DESCRIPTION

POE::Kernel is an event application kernel.  It provides a
lightweight, cooperatively-timesliced process model in addition to the
usual basic event loop functions.

POE::Kernel cooperates with three external event loops.  This is
discussed after the public methods are described.

The POE manpage describes a shortcut for using several POE modules at
once.  It also includes a complete sample program with a brief
walkthrough of its parts.

=head1 PUBLIC KERNEL METHODS

This section discusses in more detail the POE::Kernel methods that
appear in the SYNOPSIS.

=head2 Kernel Management and Data Accessors

These functions manipulate the Kernel itself or retrieve information
from it.

=over 2

=item ID

ID() returns the kernel's unique identifier.

  print "The currently running Kernel is: $kernel->ID\n";

Every POE::Kernel instance is assigned an ID at birth.  This ID tries
to differentiate any given instance from all the others, even if they
exist on the same machine.  The ID is a hash of the machine's name and
the kernel's instantiation time and process ID.

  ~/perl/poe$ perl -wl -MPOE -e 'print $poe_kernel->ID'
  rocco.homenet-39240c97000001d8

=item run

run() starts the kernel's event loop.  It returns only after every
session has stopped, or immediately if no sessions have yet been
started.

  #!/usr/bin/perl -w
  use strict;
  use POE;

  # ... start bootstrap session(s) ...

  $poe_kernel->run();
  exit;

The run() method may be called on an instance of POE::Kernel.

  my $kernel = POE::Kernel->new();
  $kernel->run();

It may also be called as class method.

  POE::Kernel->run();

The run() method does not return a meaningful value.

=back

=head2 FIFO Event Methods

FIFO events are dispatched in the order in which they were queued.
These methods queue new FIFO events.  A session will not spontaneously
stop as long as it has at least one FIFO event in the queue.

=over 2

=item post SESSION, EVENT_NAME, PARAMETER_LIST

=item post SESSION, EVENT_NAME

post() enqueues an event to be dispatched to EVENT_NAME in SESSION.
If a PARAMETER_LIST is included, its values will be passed as
arguments to EVENT_NAME's handler.

  $_[KERNEL]->post( $session, 'do_this' );
  $_[KERNEL]->post( $session, 'do_that', $with_this, $and_this );
  $_[KERNEL]->post( $session, 'do_that', @with_these );

  POE::Session->new(
    do_this => sub { print "do_this called with $_[ARG0] and $_[ARG1]\n" },
    do_that => sub { print "do_that called with @_[ARG0..$#_]\n" },
  );

The post() method returns a boolean value indicating whether the event
was enqueued successfully.  $! will explain why the post() failed:

=over 2

=item ESRCH

SESSION did not exist at the time of the post() call.

=back

Posted events keep both the sending and receiving session alive until
they're dispatched.

=item yield EVENT_NAME, PARAMETER_LIST

=item yield EVENT_NAME

yield() enqueues an EVENT_NAME event for the session that calls it.
If a PARAMETER_LIST is included, its values will be passed as
arguments to EVENT_NAME's handler.

yield() is shorthand for post() where the event's destination is the
current session.

Events posted with yield() must propagate through POE's FIFO before
they're dispatched.  This effectively yields timeslices to other
sessions which have events enqueued before it.

  $kernel->yield( 'do_this' );
  $kernel->yield( 'do_that', @with_these );

The previous yield() calls are equivalent to these post() calls.

  $kernel->post( $session, 'do_this' );
  $kernel->post( $session, 'do_that', @with_these );

The yield() method does not return a meaningful value.

=back

=head2 Synchronous Events

Sometimes it's necessary to invoke an event handler right away, for
example to handle a time-critical external event that would be spoiled
by the time an event propagated through POE's FIFO.  The kernel's
call() method provides for time-critical events.

=over 2

=item call SESSION, EVENT_NAME, PARAMETER_LIST

=item call SESSION, EVENT_NAME

call() bypasses the FIFO to call EVENT_NAME in a SESSION, optionally
with values from a PARAMETER_LIST.  The values will be passed as
arguments to EVENT_NAME at dispatch time.

call() returns whatever EVENT_NAME's handler does.  The call() call's
status is returned in $!, which is 0 for success or a nonzero reason
for failure.

  $return_value = $kernel->call( 'do_this_now' );
  die "could not do_this_now: $!" if $!;

POE uses call() to dispatch some resource events without FIFO latency.
Filehandle watchers, for example, would continue noticing a handle's
readiness until it was serviced by a handler.  This could result in
several redundant readiness events being enqueued before the first one
was dispatched.

Reasons why call() might fail:

=over 2

=item ESRCH

SESSION did not exist at the time call() was called.

=back

=head2 Delayed Events (Original Interface)

POE also manages timed events.  These are events that should be
dispatched after at a certain time or after some time has elapsed.  A
session will not spontaneously stop as long as it has at least one
pending timed event.  Alarms and delays always are enqueued for the
current session, so a SESSION parameter is not needed.

The kernel manages two types of timed event.  Alarms are set to be
dispatched at a particular time, and delays are set to go off after a
certain interval.

If Time::HiRes is installed, POE::Kernel will use it to increase the
accuracy of timed events.  The kernel will use the less accurate
built-in time() if Time::HiRes isn't available.

=over 2

=item alarm EVENT_NAME, EPOCH_TIME, PARAMETER_LIST

=item alarm EVENT_NAME, EPOCH_TIME

=item alarm EVENT_NAME

POE::Kernel's alarm() is a single-shot alarm.  It first clears all the
timed events destined for EVENT_NAME in the current session.  It then
may set a new alarm for EVENT_NAME if EPOCH_TIME is included,
optionally including values from a PARAMETER_LIST.

It is possible to post an alarm with an EPOCH_TIME in the past; in
that case, it will be placed towards the front of the event queue.

To clear existing timed events for 'do_this' and set a new alarm with
parameters:

  $kernel->alarm( 'do_this', $at_this_time, @with_these_parameters );

Clear existing timed events for 'do_that' and set a new alarm without
parameters:

  $kernel->alarm( 'do_that', $at_this_time );

To clear existing timed events for 'do_the_other_thing' without
setting a new delay:

  $kernel->alarm( 'do_the_other_thing' );

This method will clear all types of alarms without regard to how they
were set.

POE::Kernel's alarm() returns 0 on success or EINVAL if EVENT_NAME is
not defined.

=item alarm_add EVENT_NAME, EPOCH_TIME, PARAMETER_LIST

=item alarm_add EVENT_NAME, EPOCH_TIME

alarm_add() sets an additional timed event for EVENT_NAME in the
current session without clearing pending timed events.  The new alarm
event will be dispatched no earlier than EPOCH_TIME.

To enqueue additional alarms for 'do_this':

  $kernel->alarm_add( 'do_this', $at_this_time, @with_these_parameters );
  $kernel->alarm_add( 'do_this', $at_this_time );

Additional alarms can be cleared with POE::Kernel's alarm() method.

alarm_add() returns 0 on success or EINVAL if EVENT_NAME or EPOCH_TIME
is undefined.

=item delay EVENT_NAME, SECONDS, PARAMETER_LIST

=item delay EVENT_NAME, SECONDS

=item delay EVENT_NAME

delay() is a single-shot delayed event.  It first clears all the timed
events destined for EVENT_NAME in the current session.  If SECONDS is
included, it will set a new delay for EVENT_NAME to be dispatched
SECONDS seconds hence, optionally including values from a
PARAMETER_LIST.  Please note that delay()ed event are placed on the
queue and are thus asynchronous.

delay() uses whichever time(2) is available within POE::Kernel.  That
may be the more accurate Time::HiRes::time(), or perhaps not.
Regardless, delay() will do the right thing without sessions testing
for Time::HiRes themselves.

It's possible to post delays with negative SECONDS; in those cases,
they will be placed towards the front of the event queue.

To clear existing timed events for 'do_this' and set a new delay with
parameters:

  $kernel->delay( 'do_this', $after_this_much_time, @with_these );

Clear existing timed events for 'do_that' and set a new delay without
parameters:

  $kernel->delay( 'do_this', $after_this_much_time );

To clear existing timed events for 'do_the_other_thing' without
setting a new delay:

  $kernel->delay( 'do_the_other_thing' );

C<delay()> returns 0 on success or a reason for its failure: EINVAL if
EVENT_NAME is undefined.

=item delay_add EVENT_NAME, SECONDS, PARAMETER_LIST

=item delay_add EVENT_NAME, SECONDS

delay_add() sets an additional delay for EVENT_NAME in the current
session without clearing pending timed events.  The new delay will be
dispatched no sooner than SECONDS seconds hence.

To enqueue additional delays for 'do_this':

  $kernel->delay_add( 'do_this', $after_this_much_time, @with_these );
  $kernel->delay_add( 'do_this', $after_this_much_time );

Additional alarms cas be cleared with POE::Kernel's delay() method.

delay_add() returns 0 on success or a reason for failure: EINVAL if
EVENT_NAME or SECONDS is undefined.

=back

=head2 Delayed Events (June 2001 Interface)

These functions were finally added in June of 2001.  They manage
alarms and delays by unique IDs, allowing existing alarms to be moved
around, added, and removed with greater accuracy than the original
interface.

The June 2001 interface provides a different set of functions for
alarms, but their underlying semantics are the same.  Foremost, they
are always set for the current session.  That's why they don't require
a SESSION parameter.

For more information, see the previous section about the older alarms
interface.

=over 2

=item alarm_adjust ALARM_ID, DELTA

alarm_adjust adjusts an existing alarm by a number of seconds, the
DELTA, which may be positive or negative.  On success, it returns the
new absolute alarm time.

  # Move the alarm 10 seconds back in time.
  $new_time = $kernel->alarm_adjust( $alarm_id, -10 );

On failure, it returns false and sets $! to a reason for the failure.
That may be EINVAL if the alarm ID or the delta are bad values.  It
could also be ESRCH if the alarm doesn't exist (perhaps it already was
dispatched).  $! may also contain EPERM if the alarm doesn't belong to
the session trying to adjust it.

=item alarm_set EVENT_NAME, TIME, PARAMETER_LIST

=item alarm_set EVENT_NAME, TIME

Sets an alarm.  This differs from POE::Kernel's alarm() in that it
lets programs set alarms without clearing them.  Furthermore, it
returns an alarm ID which can be used in other new-style alarm
functions.

  $alarm_id = $kernel->alarm_set( party => 1000000000 )
  $kernel->alarm_remove( $alarm_id );

alarm_set sets $! and returns false if it fails.  $! will be EINVAL if
one of the function's parameters is bogus.

See: alarm_remove,

=item alarm_remove ALARM_ID

Removes an alarm from the current session, but first you must know its
ID.  The ID comes from a previous alarm_set() call, or you could hunt
at random for alarms to remove.

Upon success, alarm_remove() returns something true based on its
context.  In a list context, it returns three things: The removed
alarm's event name, its scheduled time, and a reference to the list of
parameters that were included with it.  This is all you need to
re-schedule the alarm later.

  my @old_alarm_list = $kernel->alarm_remove( $alarm_id );
  if (@old_alarm_list) {
    print "Old alarm event name: $old_alarm_list[0]\n";
    print "Old alarm time      : $old_alarm_list[1]\n";
    print "Old alarm parameters: @{$old_alarm_list[2]}\n";
  }
  else {
    print "Could not remove alarm $alarm_id: $!\n";
  }

In a scalar context, it returns a reference to a list of the three
things above.

  my $old_alarm_scalar = $kernel->alarm_remove( $alarm_id );
  if ($old_alarm_scalar) {
    print "Old alarm event name: $old_alarm_scalar->[0]\n";
    print "Old alarm time      : $old_alarm_scalar->[1]\n";
    print "Old alarm parameters: @{$old_alarm_scalar->[2]}\n";
  }
  else {
    print "Could not remove alarm $alarm_id: $!\n";
  }

Upon failure, it returns false and sets $! to the reason it failed.
$! may be EINVAL if the alarm ID is undefined, or it could be ESRCH if
no alarm was found by that ID.  It may also be EPERM if some other
session owns that alarm.

=item alarm_remove_all

alarm_remove_all() removes all alarms from the current session.  It
obviates the need for queue_peek_alarms(), which has been deprecated.

This function takes no arguments.  In scalar context, it returns a
reference to a list of alarms that were removed.  In list context, it
returns the list of removed alarms themselves.

Each removed alarm follows the same format as in alarm_remove().

  my @removed_alarms = $kernel->alarm_remove_all( );
  foreach my $alarm (@removed_alarms) {
    print "-----\n";
    print "Removed alarm event name: $alarm->[0]\n";
    print "Removed alarm time      : $alarm->[1]\n";
    print "Removed alarm parameters: @{$alarm->[2]}\n";
  }

  my $removed_alarms = $kernel->alarm_remove_all( );
  foreach my $alarm (@$removed_alarms) {
    ...;
  }

=item delay_set EVENT_NAME, SECONDS, PARAMETER_LIST

=item delay_set EVENT_NAME, SECONDS

delay_set() is a handy way to set alarms for a number of seconds
hence.  Its EVENT_NAME and PARAMETER_LIST are the same as for
alarm_set, and it returns the same things as alarm_set, both as a
result of success and of failure.

It's only difference is that SECONDS is added to the current time to
get the time the delay will be dispatched.  It uses whichever time()
POE::Kernel does, which may be Time::HiRes' high-resolution timer, if
that's available.

=back

=head2 Numeric Session IDs and Symbolic Session Names (Aliases)

Every session is given a unique ID at birth.  This ID combined with
the kernel's own ID can uniquely identify a particular session
anywhere in the world.

Sessions can also use the kernel's alias dictionary to give themselves
symbolic names.  Once a session has a name, it may be referred to by
that name wherever a kernel method expects a session reference or ID.

Sessions with aliases are treated as daemons within the current
program (servlets?).  They are kept alive even without other things to
do on the assumption that some other session will need their services.

Daemonized sessions may spontaneously self-destruct if no other
sessions are active.  This prevents "zombie" servlets from keeping a
program running with nothing to do.

=over 2

=item alias_set ALIAS

alias_set() sets an ALIAS for the current session.  The ALIAS may then
be used nearly everywhere a session reference or ID is expected.
Sessions may have more than one alias, and each must be defined in a
separate alias_set() call.

  $kernel->alias_set( 'ishmael' ); # o/` A name I call myself. o/`

Having an alias "daemonizes" a session, allowing it to stay alive even
when there's nothing for it to do.  Sessions can use this to become
autonomous services that other sessions refer to by name.

  $kernel->alias_set( 'httpd' );
  $kernel->post( httpd => set_handler => $uri_regexp => 'callback_event' );

alias_set() returns 0 on success, or a nonzero failure indicator:

=over 2

=item EEXIST

The alias already is assigned to a different session.

=back

=item alias_remove ALIAS

alias_remove() clears an existing ALIAS from the current session.  The
ALIAS will no longer refer to this session, and some other session may
claim it.

  $kernel->alias_remove( 'Shirley' ); # And don't call me Shirley.

If a session is only being kept alive by its aliases, it will stop
once they are removed.

alias_remove() returns 0 on success or a reason for its failure:

=over 2

=item ESRCH

The Kernel's dictionary does not include the ALIAS being removed.

=item EPERM

ALIAS belongs to some other session, and the current one does not have
the authority to clear it.

=back

=item alias_resolve ALIAS

alias_resolve() returns a session reference corresponding to its given
ALIAS.  This method has been overloaded over time, and now ALIAS may
be several things:

An alias:

  $session_reference = $kernel->alias_resolve( 'irc_component' );

A stringified session reference.  This is a form of weak reference:

  $blessed_session_reference = $kernel->alias_resolve( "$stringified_one" );

A numeric session ID:

  $session_reference = $kernel->alias_resolve( $session_id );

alias_resolve() returns undef upon failure, setting $! to explain the
error:

=over 2

=item ESRCH

The Kernel's dictionary does not include ALIAS.

=back

These functions work directly with session IDs.  They are faster than
alias_resolve() in the specific cases where they're useful.

=item ID_id_to_session SESSION_ID

ID_id_to_session() returns a session reference for a given numeric
session ID.

  $session_reference = ID_id_to_session( $session_id );

It returns undef if a lookup fails, and it sets $! to explain why the
lookup failed.

=over 2

=item ESRCH

The session ID does not refer to a running session.

=back

=item alias_list SESSION

=item alias_list

alias_list() returns a list of alias(es) associated with a SESSION, or
with the current session if a SESSION is omitted.

SESSION may be a session reference (either blessed or stringified), a
session ID, or a session alias.  It will be resolved into a session
reference internally, and that will be used to locate the session's
aliases.

alias_list() returns a list of aliases associated with the session.
It returns an empty list if none were found.

=item ID_session_to_id SESSION_REFERENCE

ID_session_to_id() returns the ID associated with a session reference.
This is virtually identical to SESSION_REFERENCE->ID, except that
SESSION_REFERENCE may have been stringified.  For example, this will
work, provided that the session exists:

  $session_id = ID_session_to_id( "$session_reference" );

ID_session_to_id() returns undef if a lookup fails, and it sets $! to
explain why the lookup failed.

=over 2

=item ESRCH

The session reference does not describe a session which is currently
running.

=back

=back

=head2 Filehandle Watcher Methods (Selects)

Filehandle watchers emit events when files become available to be read
from or written to.  As of POE 0.1702 these events are queued along
with all the rest.  They are no longer "synchronous" or "immediate".

Filehandle watchers are often called "selects" in POE because they
were originally implemented with the select(2) I/O multiplexing
function.

File I/O event handlers are expected to interact with filehandles in a
way that causes them to stop being ready.  For example, a
select_read() event handler should try to read as much data from a
filehandle as it can.  The filehandle will stop being ready for
reading only when all its data has been read out.

Select events include two parameters.

C<ARG0> holds the handle of the file that is ready.

C<ARG1> contains 0, 1, or 2 to indicate whether the filehandle is
ready for reading, writing, or out-of-band reading (otherwise knows as
"expedited" or "exception").

C<ARG0> and the other event handler parameter constants is covered in
L<POE::Session>.

Sessions will not spontaneously stop as long as they are watching at
least one filehandle.

=over 2

=item select_read FILE_HANDLE, EVENT_NAME

=item select_read FILE_HANDLE

select_read() starts or stops the kernel from watching to see if a
filehandle can be read from.  An EVENT_NAME event will be enqueued
whenever the filehandle has data to be read.

  # Emit 'do_a_read' event whenever $filehandle has data to be read.
  $kernel->select_read( $filehandle, 'do_a_read' );

  # Stop watching for data to be read from $filehandle.
  $kernel->select_read( $filehandle );

select_read() does not return a meaningful value.

=item select_write FILE_HANDLE, EVENT_NAME

=item select_write FILE_HANDLE

select_write() starts or stops the kernel from watching to see if a
filehandle can be written to.  An EVENT_NAME event will be enqueued
whenever it is possible to write data to the filehandle.

  # Emit 'flush_data' whenever $filehandle can be written to.
  $kernel->select_writ( $filehandle, 'flush_data' );

  # Stop watching for opportunities to write to $filehandle.
  $kernel->select_write( $filehandle );

select_write() does not return a meaningful value.

=item select_expedite FILE_HANDLE, EVENT_NAME

=item select_expedite FILE_HANDLE

select_expedite() starts or stops the kernel from watching to see if a
filehandle can be read from "out-of-band".  This is most useful for
datagram sockets where an out-of-band condition is meaningful.  In
most cases it can be ignored.  An EVENT_NAME event will be enqueued
whetever the filehandle can be read from out-of-band.

Out of band data is called "expedited" because it's often available
ahead of a file or socket's normal data.  It's also used in socket
operations such as connect() to signal an exception.

  # Emit 'do_an_oob_read' whenever $filehandle has OOB data to be read.
  $kernel->select_expedite( $filehandle, 'do_an_oob_read' );

  # Stop watching for OOB data on the $filehandle.
  $kernel->select_expedite( $filehandle );

select_expedite() does not return a meaningful value.

=item select_pause_write FILE_HANDLE

=item select_resume_write FILE_HANDLE

select_pause_write() temporarily pauses event generation when a
FILE_HANDLE can be written to.  select_resume_write() turns event
generation back on.

These functions are more efficient than select_write() because they
don't perform full resource management.

Pause and resume a filehandle's writable events:

  $kernel->select_pause_write( $filehandle );
  $kernel->select_resume_write( $filehandle );

These methods don't return meaningful values.

=item select FILE_HANDLE, READ_EVENT_NM, WRITE_EVENT_NM, EXPEDITE_EVENT_NM

POE::Kernel's select() method alters a filehandle's read, write, and
expedite selects at the same time.  It's one method call more
expensive than doing the same thing manually, but it's more convenient
to code.

Defined event names set or change the events that will be emitted when
the filehandle becomes ready.  Undefined names clear those aspects of
the watcher, stopping it from generating those types of events.

This sets all three types of events at once.

  $kernel->select( $filehandle, 'do_read', 'do_flush', 'do_read_oob' );

This clears all three types of events at once.  If this filehandle is
the only thing keeping a session alive, then clearing its selects will
stop the session.

  $kernel->select( $filehandle );

This sets up a filehandle for read-only operation.

  $kernel->select( $filehandle, 'do_read', undef, 'do_read_oob' );

This sets up a filehandle for write-only operation.

  $kernel->select( $filehandle, undef, 'do_flush' );

This method does not return a meaningful value.

=back

=head2 Signal Watcher Methods

First some general notes about signal events and handling them.

Signal events are dispatched to sessions that have registered interest
in them via the C<sig()> method.  For backward compatibility, every
other session will receive a _signal event after that.  The _signal
event is scheduled to be removed in version 0.22, so please use
C<sig()> to register signal handlers instead.  In the meantime,
_signal events contain the same parameters as ones generated by
C<sig()>.  L<POE::Session> covers signal events in more details.

Signal events propagate to child sessions before their parents.  This
ensures that leaves of the parent/child tree are signaled first.  By
the time a session receives a signal, all its descendents already
have.

The Kernel acts as the ancestor of every session.  Signalling it, as
the operating system does, propagates signal events to every session.

It is possible to post fictitious signals from within POE.  These are
injected into the queue as if they came from the operating system, but
they are not limited to signals that the system recognizes.  POE uses
fictitious signals to notify every session about certain global
events, such as when a user interface has been destroyed.

Sessions that do not handle signal events may incur side effects.  In
particular, some signals are "terminal", in that they terminate a
program if they are not handled.  Many of the signals that usually
stop a program in UNIX are terminal in POE.

POE also recognizes "non-maskable" signals.  These will terminate a
program even when they are handled.  The signal that indicates user
interface destruction is just such a non-maskable signal.

Event handlers use C<sig_handled()> to tell POE when a signal has been
handled.  Some unhandled signals will terminate a program.  Handling
them is important if that is not desired.

Event handlers can also implicitly tell POE when a signal has been
handled, simply by returning some true value.  This is deprecated,
however, because it has been the source of constant trouble in the
past.  Please use C<sig_handled()> in its place.

Handled signals will continue to propagate through the parent/child
hierarchy.

Signal handling in Perl is not safe by itself.  POE is written to
avoid as many signal problems as it can, but they still may occur.
SIGCHLD is a special exception: POE polls for child process exits
using waitpid() instead of a signal handler.  Spawning child processes
should be completely safe.

There are three signal levels.  They are listed from least to most
strident.

=over 2

=item benign

Benign signals just notify sessions that signals have been received.
They have no side effects if they are not handled.

=item terminal

Terminal signal may stop a program if they go unhandled.  If any event
handler calls C<sig_handled()>, however, then the program will
continue to live.

In the past, only sessions that handled signals would survive.  All
others would be terminated.  This led to inconsistent states when some
programs were signaled.

The terminal system signals are: HUP, INT, KILL, QUIT and TERM.  There
is also one terminal fictitious signal, IDLE, which is used to notify
leftover sessions when a program has run out of things to do.

=item nonmaskable

Nonmaskable signals are similar to terminal signals, but they stop a
program regardless whether it has been handled.  POE implements two
nonmaskable signals, both of which are fictitious.

ZOMBIE is fired if the terminal signal IDLE did not wake anything up.
It is used to stop the remaining "zombie" sessions so that an inactive
program will exit cleanly.

UIDESTROY is fired when a main or top-level user interface widget has
been destroyed.  It is used to shut down programs when their
interfaces have been closed.

=back

Some system signals are handled specially.  These are SIGCHLD/SIGCLD,
SIGPIPE, and SIGWINCH.

=over 2

=item SIGCHLD/SIGCLD Events

POE::Kernel generates the same event when it receives either a SIGCHLD
or SIGCLD signal from the operating system.  This alleviates the need
for sessions to check both signals.

Additionally, the Kernel will determine the ID and return value of the
exiting child process.  The values are broadcast to every session, so
several sessions can check whether a departing child process is
theirs.

The SIGCHLD/SIGCHLD signal event comes with three custom parameters.

C<ARG0> contains 'CHLD', even if SIGCLD was caught.  C<ARG1> contains
the ID of the exiting child process.  C<ARG2> contains the return
value from C<$?>.

=item SIGPIPE Events

Normally, system signals are posted to the Kernel so they can
propagate to every session.  SIGPIPE is an exception to this rule.  It
is posted to the session that is currently running.  It still will
propagate through that session's children, but it will not go beyond
that parent/child tree.

=item SIGWINCH Events

Window resizes can generate a large number of signals very quickly,
and this can easily cause perl to dump core.  Because of this, POE
usually ignores SIGWINCH outright.

Signal handling in Perl 5.8.0 will be safer, and POE will take
advantage of that to enable SIGWINCH again.

POE will also handle SIGWINCH if the Event module is used.

=back

Finally, here are POE::Kernel's signal methods themselves.

=over 2

=item sig SIGNAL_NAME, EVENT_NAME

=item sig SIGNAL_NAME

sig() registers or unregisters a EVENT_NAME event for a particular
SIGNAL_NAME.  Signal names are the same as %SIG uses, with one
exception: CLD is always delivered as CHLD, so handling CHLD will
always do the right thing.

  $kernel->sig( INT => 'event_sigint' );

To unregister a signal handler, just leave off the event it should
generate, or pass it in undefined.

  $kernel->sig( 'INT' );
  $kernel->sig( INT => undef );

It's possible to register events for signals that the operating system
will never generate.  These "fictitious" signals can however be
generated through POE's signal() method instead of kill(2).

The sig() method does not return a meaningful value.

=item sig_handled

sig_handled() informs POE that a signal was handled.  It is only
meaningful within event handlers that are triggered by signals.

=item signal SESSION, SIGNAL_NAME

signal() posts a signal event to a particular session (and its
children) through POE::Kernel rather than actually signalling the
process through the operating system.  Because it injects signal
events directly into POE's Kernel, its SIGNAL_NAME doesn't have to be
one the operating system understands.

For example, this posts a fictitious signal to some session:

  $kernel->signal( $session, 'DIEDIEDIE' );

POE::Kernel's signal() method doesn't return a meaningful value.

=item signal_ui_destroy WIDGET

This registers a widget with POE::Kernel such that the Kernel fires a
UIDESTROY signal when the widget is closed or destroyed.  The exact
trigger depends on the graphical toolkit currently being used.

  # Fire a UIDESTROY signal when this top-level window is deleted.
  $heap->{gtk_toplevel_window} = Gtk::Window->new('toplevel');
  $kernel->signal_ui_destroy( $heap->{gtk_toplevel_window} );

=back

=head2 Session Management Methods

These methods manage sessions.

=over 2

=item detach_child SESSION

Detaches SESSION from the current session.  SESSION must be a child of
the current session, or this call will fail.  detach_child() returns 1
on success.  If it fails, it returns false and sets $! to one of the
following values:

ESRCH indicates that SESSION is not a valid session.

EPERM indicates that SESSION is not a child of the current session.

This call may generate corresponding _parent and/or _child events.
See PREDEFINED EVENT NAMES in POE::Session's manpage for more
information about _parent and _child events.

=item detach_myself

Detaches the current session from it parent.  The parent session stops
owning the current one.  The current session is instead made a child
of POE::Kernel.  detach_child() returns 1 on success.  If it fails, it
returns 0 and sets $! to EPERM to indicate that the currest session
already is a child of POE::Kernel and cannot be detached from it.

This call may generate corresponding _parent and/or _child events.
See PREDEFINED EVENT NAMES in POE::Session's manpage for more
information about _parent and _child events.

=back

=head2 State Management Methods

State management methods let sessions hot swap their event handlers.
It would be rude to change another session's handlers, so these
methods only affect the current one.

=over 2

=item state EVENT_NAME

=item state EVENT_NAME, CODE_REFERENCE

=item state EVENT_NAME, OBJECT_REFERENCE

=item state EVENT_NAME, OBJECT_REFERENCE, OBJECT_METHOD_NAME

=item state EVENT_NAME, PACKAGE_NAME

=item state EVENT_NAME, PACKAGE_NAME, PACKAGE_METHOD_NAME

Depending on how it's used, state() can add, remove, or update an
event handler in the current session.

The simplest form of state() call deletes a handler for an event.
This example removes the current session's "do_this" handler.

  $kernel->state( 'do_this' );

The next form assigns a coderef to an event.  If the event is already
being handled, its old handler will be discarded.  Any events already
in POE's queue will be dispatched to the new handler.

Plain coderef handlers are also called "inline" handlers because they
originally were defined with inline anonymous subs.

  $kernel->state( 'do_this', \&this_does_it );

The third and fourth forms register or replace a handler with an
object method.  These handlers are called "object states" or object
handlers.  The third form maps an event to a method with the same
name.

  $kernel->state( 'do_this', $with_this_object );

The fourth form maps an event to a method with a different name.

  $kernel->state( 'do_this', $with_this_object, $calling_this_method );

The fifth and sixth forms register or replace a handler with a package
method.  These handlers are called "package states" or package
handlers.  The fifth form maps an event to a function with the same
name.

  $kernel->state( 'do_this', $with_this_package );

The sixth form maps an event to a function with a different name.

  $kernel->state( 'do_this', $with_this_package, $calling_this_function );

POE::Kernel's state() method returns 0 on success or a nonzero code
explaining why it failed:

=over 2

=item ESRCH

The Kernel doesn't recognize the currently active session.  This
happens when state() is called when no session is active.

=back

=head2 External Reference Count Methods

The Kernel internally maintains reference counts on sessions that have
active resource watchers.  The reference counts are used to ensure
that a session doesn't self-destruct while it's doing something
important.

POE::Kernel's external reference counting methods let resource watcher
developers manage their own reference counts.  This lets the watchers
keep their sessions alive when necessary.

=over 2

=item refcount_increment SESSION_ID, REFCOUNT_NAME

=item refcount_decrement SESSION_ID, REFCOUNT_NAME

refcount_increment() increments a session's external reference count,
returning the reference count after the increment.

refcount_decrement() decrements a session's external reference count,
returning the reference count after the decrement.

  $new_count = $kernel->refcount_increment( $session_id, 'thingy' );
  $new_count = $kernel->refcount_decrement( $session_id, 'thingy' );

Both methods return undef on failure and set $! to explain the
failure.

=over 2

=item ESRCH

There is no session SESSION_ID currently active.

=back

=back

=head2 Kernel Data Accessors

The Kernel keeps some information which can be useful to other
libraries.  These functions provide a consistent, safe interface to
the Kernel's internal data.

=over 2

=item get_active_session

get_active_session() returns a reference to the session which is
currently running.  It returns a reference to the Kernel itself if no
other session is running.  This is one of the times where the Kernel
pretends it's just another session.

  my $active_session = $poe_kernel->get_active_session();

This is a convenient way for procedurally called libraries to get a
reference to the current session.  Otherwise a programmer would
tediously need to include C<SESSION> with every call.

=back

=head1 Using POE with Other Event Loops

POE::Kernel supports four event loops.  Three of them come from other
modules, and the Kernel will adapt to whichever one is loaded before
it.  The Kernel's resource functions are designed to work the same
regardless of the underlying event loop.

=over 2

=item POE's select() Loop

This is the default event loop.  It is included in POE::Kernel and
written in plain Perl for maximum portability.

  use POE;

=item Event's Loop

Event is written in C for maximum performance.  It requires either a C
compiler or a binary distribtution for your platform, and its C nature
allows it to implement safe signals.

  use Event;
  use POE;

=item Gtk's Event Loop

This loop allows POE to work in graphical programs using the Gtk-Perl
library.

  use Gtk;
  use POE;

=item IO::Poll

IO::Poll is potentially more efficient than POE's default select()
code in large scale clients and servers.

  use IO::Poll;
  use POE;

=item Tk's Event Loop

This loop allows POE to work in graphical programs using the Tk-Perl
library.

  use Tk;
  use POE;

=back

External event loops expect plain coderefs as callbacks.  POE::Session
has a postback() method which will create callbacks these loops can
use.  Callbacks created with C<postback()> are designed to post POE
events when called, letting just about any loop's native callbacks
work with POE.  This includes widget callbacks and event watchers POE
never dreamt of.

=head2 Kernel's Debugging Features

POE::Kernel contains a number of debugging assertions and traces.

Assertions remain quiet until something wrong has been detected; then
they die right away with an error.  They're mainly used for sanity
checking in POE's test suite and to make the developers' lives easier.
Traces, on the other hand, are never fatal, but they're terribly
noisy.

Both assertions and traces incur performance penalties, so they should
be used sparingly, if at all.  They all are off by default.  POE's
test suite runs slower than normal because assertions are enabled
during all the tests.

Assertion and tracing constants can be redefined before POE::Kernel is
first used.

  # Turn on everything.
  sub POE::Kernel::ASSERT_DEFAULT () { 1 }
  sub POE::Kernel::TRACE_DEFAULT  () { 1 }
  use POE;

Assertions will be discussed first.

=over 2

=item ASSERT_DEFAULT

ASSERT_DEFAULT is used as the default value for all the other assert
constants.  Setting it true is a quick and reliable way to ensure all
assertions are enabled.

=item ASSERT_GARBAGE

ASSERT_GARBAGE turns on checks for proper garbage collection.  In
particular, it ensures that sessions have released all their resources
before they're destroyed.

=item ASSERT_REFCOUNT

ASSERT_REFCOUNT enables checks for negative reference counts.

=item ASSERT_RELATIONS

ASSERT_RELATIONS turns on parent/child referential integrity checks.

=item ASSERT_RETURNS

ASSERT_RETURNS causes POE::Kernel's methods to confess instead of
returning error codes.  See also TRACE_RETURNS if you don't want the
Kernel to be so strict.

=item ASSERT_SELECT

ASSERT_SELECT enables extra error checking in the Kernel's select
logic.  It has no effect if POE is using an external event loop.

=item ASSERT_SESSIONS

ASSERT_SESSIONS makes it fatal to send an event to a nonexistent
session.

=item ASSERT_USAGE

ASSERT_USAGE enables runtime parameter checking in a lot of
POE::Kernel method calls.  These are disabled by default because they
impart a hefty performance penalty.

=back

Then there are the trace options.

=over 2

=item TRACE_DEFAULT

TRACE_DEFAULT is used as the default value for all the other trace
constants.  Setting it true is a quick and reliable way to ensure all
traces are enabled.

=item TRACE_EVENTS

The music goes around and around, and it comes out here.  TRACE_EVENTS
enables messages that tell what happens to FIFO and alarm events: when
they're queued, dispatched, or discarded, and what their handlers
return.

=item TRACE_GARBAGE

TRACE_GARBAGE shows what's keeping sessions alive.  It's useful for
determining why a session simply refuses to die, or why it won't stick
around.

=item TRACE_PROFILE

TRACE_PROFILE switches on event profiling.  This causes the Kernel to
keep a count of every event it dispatches.  It displays a frequency
report when run() is about to return.

=item TRACE_QUEUE

TRACE_QUEUE complements TRACE_EVENTS.  When enabled, it traces the
contents of POE's event queues, giving some insight into how events
are ordered.  This has become less relevant since the alarm and FIFO
queues have separated.

=item TRACE_REFCOUNT

TRACE_REFCOUNT enables debugging output whenever an external reference
count changes.

=item TRACE_RETURNS

TRACE_RETURNS enables carping whenever a Kernel method is about to
return an error.  See ASSERT_RETURNS if you'd like the Kernel to be
stricter than this.

=item TRACE_SELECT

TRACE_SELECT enables or disables statistics about C<select()>'s
parameters and return values.  It's only relevant when using POE's own
select() loop.

=item TRACE_SIGNALS

TRACE_SIGNALS enables or disables information about signals caught and
dispatched within POE::Kernel.

=back

=head1 POE::Kernel Exports

POE::Kernel exports two symbols for your coding enjoyment:
C<$poe_kernel> and C<$poe_main_window>.  POE::Kernel is implicitly
used by POE itself, so using POE gets you POE::Kernel (and its
exports) for free.

=over 2

=item $poe_kernel

$poe_kernel contains a reference to the process' POE::Kernel instance.
It's mainly useful for getting at the kernel from places other than
event handlers.

For example, programs can't call the Kernel's run() method without a
reference, and they normally don't get references to the Kernel
without being in a running event handler.  This gets them going:

  $poe_kernel->run();

It's also handy from within libraries, but event handlers themselves
receive C<KERNEL> parameters and don't need to use $poe_kernel
directly.

=item $poe_main_window

Some graphical toolkits (currently only Tk) require at least one
widget be created before their event loops are usable.  POE::Kernel
allocates a main window in these cases, and exports a reference to
that window in C<$poe_main_window>.  For all other toolkits, this
exported variable is undefined.

Programs are free to use C<$poe_main_window> for whatever needs.  They
may even assign a widget to it when using toolkits that don't require
an initial widget (Gtk for now).

$poe_main_window is undefined if a graphical toolkit isn't used.

See: signal_ui_destroy

=back

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

There is no mechanism in place to prevent external reference count
names from clashing.

Probably lots more.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
