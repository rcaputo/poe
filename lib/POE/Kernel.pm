# $Id$

package POE::Kernel;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use POSIX qw(errno_h fcntl_h sys_wait_h);
use Carp qw(carp croak confess);
use Sys::Hostname qw(hostname);

# People expect these to be lexical.

use vars qw( $poe_kernel $poe_main_window );

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
    import  Time::HiRes qw(time sleep);
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

# Translate event IDs to absolute event due time.  This is used by the
# alarm functions to speed up finding alarms by ID.
#
# { $event_id => $event_due_time,
#   ...,
# }
my %kr_event_ids;

# Translate session IDs to blessed session references.  Used for
# session ID to reference lookups in alias_resolve.
#
# { $session_id => $session_reference,
#   ...,
# }
my %kr_session_ids;

# Map a signal name to the sessions that are explicitly watching it.
# For each explicit signal watcher, also note the event that the
# signal will generate.
#
# { $signal_name =>
#   { $session_reference => $event_name,
#     ...,
#   }
# }
my %kr_signals;

# Bookkeeping per dispatched signal.

my @kr_signaled_sessions;
my $kr_signal_total_handled;
my $kr_signal_handled_implicitly;
my $kr_signal_handled_explicitly;
my $kr_signal_type;

# The table of session aliases, and the sessions they refer to.
#
# { $alias => $session_reference,
#   ...,
# }
my %kr_aliases;

# The count of all extra references used in the system.
my $kr_extra_refs = 0;

# A flag determining whether there are child processes.  Starts true
# so our waitpid() loop can run at least once.
my $kr_child_procs = 1;

# The session ID index.  It increases as each new session is
# allocated.
my $kr_id_index = 1;

# A reference to the currently active session.  Used throughout the
# functions that act on the current session.
my $kr_active_session;

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
sub KR_EVENTS         () {  5 } #   \@kr_events,
sub KR_ID             () {  6 } #   $unique_kernel_id,
sub KR_SESSION_IDS    () {  7 } #   \%kr_session_ids,
sub KR_ID_INDEX       () {  8 } #   \$kr_id_index,
sub KR_EXTRA_REFS     () {  9 } #   \$kr_extra_refs,
sub KR_EVENT_IDS      () { 10 } #   \%kr_event_ids,
sub KR_SIZE           () { 11 } #   XXX UNUSED ???
                                # ]

# This flag indicates that POE::Kernel's run() method was called.
# It's used to warn about forgetting $poe_kernel->run().

sub KR_RUN_CALLED  () { 0x01 }  # $kernel->run() called
sub KR_RUN_SESSION () { 0x02 }  # sessions created
sub KR_RUN_DONE    () { 0x04 }  # run returned
my $kr_run_warning = 0;

#------------------------------------------------------------------------------
# Session structure.

my %kr_sessions;

sub SS_SESSION    () {  0 } #  [ $blessed_session,
sub SS_REFCOUNT   () {  1 } #    $total_reference_count,
sub SS_EVCOUNT    () {  2 } #    $pending_inbound_event_count,
sub SS_PARENT     () {  3 } #    $parent_session,
sub SS_CHILDREN   () {  4 } #    { $child_session => $child_session,
                            #      ...
                            #    },
sub SS_HANDLES    () {  5 } #    { $file_handle =>
# --- BEGIN SUB STRUCT ---  #      [
sub SH_HANDLE     () {  0 } #        $blessed_file_handle,
sub SH_REFCOUNT   () {  1 } #        $total_reference_count,
sub SH_VECCOUNT   () {  2 } #        [ $read_reference_count,     (VEC_RD)
                            #          $write_reference_count,    (VEC_WR)
                            #          $expedite_reference_count, (VEC_EX)
# --- CEASE SUB STRUCT ---  #      ],
                            #      ...
                            #    },
sub SS_SIGNALS    () {  6 } #    { $signal_name => $event_name,
                            #      ...
                            #    },
sub SS_ALIASES    () {  7 } #    { $alias_name => $placeholder_value,
                            #      ...
                            #    },
sub SS_PROCESSES  () {  8 } #    { $process_id => $placeholder_value,
                            #      ...
                            #    },
sub SS_ID         () {  9 } #    $unique_session_id,
sub SS_EXTRA_REFS () { 10 } #    { $reference_count_tag => $reference_count,
                            #      ...
                            #    },
sub SS_POST_COUNT () { 11 } #    $pending_outbound_event_count,
                            #  ]

#------------------------------------------------------------------------------
# Fileno structure.  This tracks the sessions that are watchin a file,
# by its file number.  It used to track by file handle, but several
# handles can point to the same underlying fileno.  This is more
# unique.

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

# These are the values for FVC_ST_ACTUAL and FVC_ST_REQUEST.

sub HS_STOPPED   () { 0x00 }   # The file has stopped generating events.
sub HS_PAUSED    () { 0x01 }   # The file temporarily stopped making events.
sub HS_RUNNING   () { 0x02 }   # The file is running and can generate events.

#------------------------------------------------------------------------------
# Events themselves.  TODO: Rename them to EV_* instead of the old
# ST_* "state" names.

my @kr_events;

sub ST_SESSION    () { 0 }  # [ $destination_session,
sub ST_SOURCE     () { 1 }  #   $sender_session,
sub ST_NAME       () { 2 }  #   $event_name,
sub ST_TYPE       () { 3 }  #   $event_type,
sub ST_ARGS       () { 4 }  #   \@event_parameters_arg0_etc,
                            #
                            #   (These fields go towards the end
                            #   because they are optional in some
                            #   cases.  TODO: Is this still true?)
                            #
sub ST_TIME       () { 5 }  #   $event_due_time,
sub ST_OWNER_FILE () { 6 }  #   $caller_filename_where_enqueued,
sub ST_OWNER_LINE () { 7 }  #   $caller_line_where_enqueued,
sub ST_SEQ        () { 8 }  #   $unique_event_id,
                            # ]

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
      eval "sub TRACE_$name () { TRACE_DEFAULT }";
    }
  }
}

# Shorthand for defining an assert constant.
sub define_assert {
  no strict 'refs';
  foreach my $name (@_) {
    unless (defined *{"ASSERT_$name"}{CODE}) {
      eval "sub ASSERT_$name () { ASSERT_DEFAULT }";
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
    qw(EVENTS GARBAGE PROFILE QUEUE REFCOUNT RETURNS SELECT SIGNALS);

  # See the notes for TRACE_DEFAULT, except read ASSERT and assert
  # where you see TRACE and trace.

  my $assert_default = 0;
  $assert_default++ if defined $ENV{POE_ASSERT_DEFAULT};
  defined &ASSERT_DEFAULT or eval "sub ASSERT_DEFAULT () { $assert_default }";

  define_assert
    qw(EVENTS GARBAGE REFCOUNT RELATIONS SELECT SESSIONS RETURNS USAGE);
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
    require POE::Kernel::Gtk;
    POE::Kernel::Gtk->import();
  }

  if (exists $INC{'Tk.pm'}) {
    require POE::Kernel::Tk;
    POE::Kernel::Tk->import();
  }

  if (exists $INC{'Event.pm'}) {
    require POE::Kernel::Event;
    POE::Kernel::Event->import();
  }

  if (exists $INC{'IO/Poll.pm'}) {
    if ($^O eq 'MSWin32') {
      warn "IO::Poll has issues on $^O.  Using select() instead for now.\n";
    }
    else {
      require POE::Kernel::Poll;
      POE::Kernel::Poll->import();
    }
  }

  unless (defined &POE_LOOP) {
    require POE::Kernel::Select;
    POE::Kernel::Select->import();
  }
}

#------------------------------------------------------------------------------
# Helper functions.  Many of these are called as plain functions; not
# methods.  We probably will need to fix that later, since we'll want
# POE::Kernel completely inheritable.

sub sig_remove {
  my ($session, $signal) = @_;
  delete $kr_sessions{$session}->[SS_SIGNALS]->{$signal};
  delete $kr_signals{$signal}->{$session};
  delete $kr_signals{$signal} unless keys %{$kr_signals{$signal}};
}

sub sid {
  my $session = shift;
  "session " . $session->ID . " (" .
    ( (keys %{$kr_sessions{$session}->[SS_ALIASES]})
      ? join(", ", keys(%{$kr_sessions{$session}->[SS_ALIASES]}) )
      : $session
    ). ")"
}

sub assert_session_refcount {
  my ($session, $refcount_index) = @_;
  if (ASSERT_REFCOUNT) {
    die sid($session), " reference count $refcount_index went below zero"
      if $kr_sessions{$session}->[$refcount_index] < 0;
  }
}

sub ses_refcount_dec {
  my $session = shift;
  $kr_sessions{$session}->[SS_REFCOUNT]--;
  assert_session_refcount($session, SS_REFCOUNT);
}

sub ses_refcount_dec2 {
  my ($session, $refcount_index) = @_;
  $kr_sessions{$session}->[$refcount_index]--;
  assert_session_refcount($session, $refcount_index);
  ses_refcount_dec($session);
}

sub ses_refcount_inc {
  my $session = shift;
  $kr_sessions{$session}->[SS_REFCOUNT]++;
}

sub ses_refcount_inc2 {
  my ($session, $refcount_index) = @_;
  $kr_sessions{$session}->[$refcount_index]++;
  ses_refcount_inc($session);
}

sub remove_extra_reference {
  my ($session, $tag) = @_;

  delete $kr_sessions{$session}->[SS_EXTRA_REFS]->{$tag};

  ses_refcount_dec($session);

  $kr_extra_refs--;
  if (ASSERT_REFCOUNT) {
    die( "--- ", sid($session), " refcounts for kernel dropped below 0")
      if $kr_extra_refs < 0;
  }
}

# Resolve $whatever into a session reference.  Try as many different
# methods as we can.  This is the internal version of alias_resolve().

sub _alias_resolve {
  my $whatever = shift;

  # Resolve against sessions.
  return $kr_sessions{$whatever}->[SS_SESSION]
    if exists $kr_sessions{$whatever};

  # Resolve against IDs.
  return $kr_session_ids{$whatever}
    if exists $kr_session_ids{$whatever};

  # Resolve against aliases.
  return $kr_aliases{$whatever}
    if exists $kr_aliases{$whatever};

  # Resolve against the Kernel itself.  Use "eq" instead of "==" here
  # because $whatever is often a string.
  return $whatever if $whatever eq $poe_kernel;

  # We don't know what it is.
  return undef;
}

sub collect_garbage {
  my ($self, $session) = @_;

  if ($session != $self) {
    # The next line is necessary for some strange reason.  This feels
    # like a kludge, but I'm currently not smart enough to figure out
    # what it's working around.
    if (exists $kr_sessions{$session}) {
      if (TRACE_GARBAGE) {
        $self->trace_gc_refcount($session);
      }
      if (ASSERT_GARBAGE) {
        $self->assert_gc_refcount($session);
      }

      if ( (exists $kr_sessions{$session})
           and (!$kr_sessions{$session}->[SS_REFCOUNT])
         ) {
        $self->session_free($session);
      }
    }
  }
}

sub handle_is_good {
  my ($handle, $vector) = @_;

  # Don't bother if the kernel isn't tracking the file.
  return 0 unless exists $kr_filenos{fileno($handle)};

  # Don't bother if the kernel isn't tracking the file mode.
  return 0 unless $kr_filenos{fileno($handle)}->[$vector]->[FVC_REFCOUNT];

  return 1;
}

sub remove_alias {
  my ($session, $alias) = @_;
  delete $kr_aliases{$alias};
  delete $kr_sessions{$session}->[SS_ALIASES]->{$alias};
  ses_refcount_dec($session);
}

sub explain_resolve_failure {
  my $whatever = shift;
  local $Carp::CarpLevel = 2;

  if (ASSERT_SESSIONS) {
    confess "Cannot resolve $whatever into a session reference\n";
  }
  $! = ESRCH;
  TRACE_RETURNS  and carp  "session not resolved: $!";
  ASSERT_RETURNS and croak "session not resolved: $!";
}

sub explain_return {
  my $message = shift;
  local $Carp::CarpLevel = 2;
  ASSERT_RETURNS and croak $message;
  TRACE_RETURNS  and carp  $message;
}

sub explain_usage {
  my $message = shift;
  local $Carp::CarpLevel = 2;
  ASSERT_USAGE   and croak $message;
  ASSERT_RETURNS and croak $message;
  TRACE_RETURNS  and carp  $message;
}

sub test_for_idle_poe_kernel {
  if (TRACE_REFCOUNT) {
    warn( ",----- Kernel Activity -----\n",
          "| Events : ", scalar(@kr_events), "\n",
          "| Files  : ", scalar(keys %kr_filenos), "\n",
          "|   `--> : ", join(', ', sort { $a <=> $b } keys %kr_filenos), "\n",
          "| Extra  : $kr_extra_refs\n",
          "| Procs  : $kr_child_procs\n",
          "`---------------------------\n",
          " ..."
         );
  }

  unless ( @kr_events > 1           or  # > 1 for signal poll loop
           scalar(keys %kr_filenos) or
           $kr_extra_refs           or
           $kr_child_procs
         ) {
    $poe_kernel->_enqueue_event
      ( $poe_kernel, $poe_kernel,
        EN_SIGNAL, ET_SIGNAL, [ 'IDLE' ],
        time(), __FILE__, __LINE__
      ) if keys %kr_sessions;
  }
}

sub post_plain_signal {
  my ($destination, $signal_name) = @_;
  $poe_kernel->_enqueue_event
    ( $destination, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL, [ $signal_name ],
      time(), __FILE__, __LINE__
    );
}

sub dispatch_due_events {
  # Pull due events off the queue, and dispatch them.
  my $now = time();
  while ( @kr_events and ($kr_events[0]->[ST_TIME] <= $now) ) {
    my $event = shift @kr_events;
    delete $kr_event_ids{$event->[ST_SEQ]};
    ses_refcount_dec2($event->[ST_SESSION], SS_EVCOUNT);
    ses_refcount_dec2($event->[ST_SOURCE], SS_POST_COUNT);
    $poe_kernel->_dispatch_event(@$event);
  }
}

sub enqueue_ready_selects {
  my ($fileno, $vector) = @_;

  die "internal inconsistency: undefined fileno" unless defined $fileno;
  my $kr_fno_vec = $kr_filenos{$fileno}->[$vector];

  # Gather all the events to emit for this fileno/vector pair.

  my @selects = map { values %$_ } values %{ $kr_fno_vec->[FVC_SESSIONS] };

  # Emit them.

  foreach my $select (@selects) {
    $poe_kernel->_enqueue_event
      ( $select->[HSS_SESSION], $select->[HSS_SESSION],
        $select->[HSS_STATE], ET_SELECT,
        [ $select->[HSS_HANDLE], $vector ],
        time(), __FILE__, __LINE__,
      );

    unless ($kr_fno_vec->[FVC_EV_COUNT]++) {
      my $handle = $select->[HSS_HANDLE];
      loop_pause_filehandle_watcher($kr_fno_vec, $handle, $vector);
    }

    if (TRACE_SELECT) {
      warn( "+++ incremented event count in vector ($vector) ",
            "for fileno ($fileno) to count ($kr_fno_vec->[FVC_EV_COUNT])"
          );
    }
  }
}

#==============================================================================
# SIGNALS
#==============================================================================

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

# As of version 0.1206, signal handlers and the functions that watch
# them have been moved into loop modules.

#------------------------------------------------------------------------------
# Register or remove signals.

# Public interface for adding or removing signal handlers.

sub sig {
  my ($self, $signal, $event_name) = @_;

  ASSERT_USAGE and do {
    croak "undefined signal in sig()" unless defined $signal;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved assigning it to a signal"
        ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  if (defined $event_name) {
    my $session = $kr_active_session;
    $kr_sessions{$session}->[SS_SIGNALS]->{$signal} = $event_name;
    $kr_signals{$signal}->{$session} = $event_name;
  }
  else {
    sig_remove($kr_active_session, $signal);
  }
}

# Public interface for posting signal events.

sub signal {
  my ($self, $destination, $signal, @etc) = @_;

  ASSERT_USAGE and do {
    croak "undefined destination in signal()" unless defined $destination;
    croak "undefined signal in signal()" unless defined $signal;
  };

  my $session = _alias_resolve($destination);
  unless (defined $session) {
    explain_resolve_failure($destination);
    return;
  }

  $self->_enqueue_event
    ( $session, $kr_active_session,
      EN_SIGNAL, ET_SIGNAL, [ $signal, @etc ],
      time(), (caller)[1,2]
    );
}

# Public interface for flagging signals as handled.  This will replace
# the handlers' return values as an implicit flag.  Returns undef so
# it may be used as the last function in an event handler.

sub sig_handled {
  my $self = shift;
  $kr_signal_total_handled = 1;
  $kr_signal_handled_explicitly = 1;
}

# Attach a window or widget's destroy/closure to the UIDESTROY signal.

sub signal_ui_destroy {
  my ($self, $window) = @_;
  loop_attach_uidestroy($self, $window);
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

    my $self = $poe_kernel = bless
      [ \%kr_sessions,       # KR_SESSIONS
        \%kr_filenos,        # KR_FILENOS
        \%kr_signals,        # KR_SIGNALS
        \%kr_aliases,        # KR_ALIASES
        \$kr_active_session, # KR_ACTIVE_SESSION
        \@kr_events,         # KR_EVENTS
        undef,               # KR_ID
        \%kr_session_ids,    # KR_SESSION_IDS
        \$kr_id_index,       # KR_ID_INDEX
        \$kr_extra_refs,     # KR_EXTRA_REFS
        \%kr_event_ids,      # KR_EVENT_IDS
      ], $type;

    # Kernel ID, based on Philip Gwyn's code.  I hope he still can
    # recognize it.  KR_SESSION_IDS is a hash because it will almost
    # always be sparse.  This goes before signals are registered
    # because it sometimes spawns /bin/hostname or the equivalent,
    # generating spurious CHLD signals before the Kernel is fully
    # initialized.

    my $hostname = eval { (POSIX::uname)[1] };
    $hostname = hostname() unless defined $hostname;

    $self->[KR_ID] =
      ( $hostname . '-' .  unpack 'H*', pack 'N*', time, $$ );
    $kr_session_ids{$self->[KR_ID]} = $self;

    # Start the Kernel's session.
    _initialize_kernel_session();
    _initialize_kernel_signals();
  }

  # Return the global instance.
  $poe_kernel;
}

sub _get_kr_sessions_ref  { \%kr_sessions }
sub _get_kr_events_ref    { \@kr_events }
sub _get_kr_event_ids_ref { \%kr_event_ids }
sub _get_kr_filenos_ref   { \%kr_filenos }

#------------------------------------------------------------------------------
# Send an event to a session right now.  Used by _disp_select to
# expedite select() events, and used by run() to deliver posted events
# from the queue.

# This is for collecting event frequencies if TRACE_PROFILE is enabled.
my %profile;

# Dispatch an event to its session.  A lot of work goes on here.

sub _dispatch_event {
  my ( $self, $session, $source_session, $event, $type, $etc, $time,
       $file, $line, $seq
     ) = @_;

  my $local_event = $event;

  if (TRACE_PROFILE) {
    $profile{$event}++;
  }

  # Pre-dispatch processing.

  unless ($type & (ET_USER | ET_CALL)) {

    # The _start event is dispatched immediately as part of allocating
    # a session.  Set up the kernel's tables for this session.

    if ($type & ET_START) {

      # Get a new session ID.  Prevent collisions.  Prevent integer
      # wraparound to a negative number.
      while (1) {
        $kr_id_index = 0 if ++$kr_id_index < 0;
        last unless exists $kr_session_ids{$kr_id_index};
      }

      my $new_session = $kr_sessions{$session} =
        [ $session,         # SS_SESSION
          0,                # SS_REFCOUNT
          0,                # SS_EVCOUNT
          $source_session,  # SS_PARENT
          { },              # SS_CHILDREN
          { },              # SS_HANDLES
          { },              # SS_SIGNALS
          { },              # SS_ALIASES
          { },              # SS_PROCESSES
          $kr_id_index,     # SS_ID
          { },              # SS_EXTRA_REFS
          0,                # SS_POST_COUNT
        ];

      # For the ID to session reference lookup.
      $kr_session_ids{$kr_id_index} = $session;

      if (ASSERT_RELATIONS) {
        # Ensure sanity.
        die sid($session), " is its own parent\a"
          if $session == $source_session;

        die( sid($session),
             " already is a child of ", sid($source_session), "\a"
           )
          if (exists $kr_sessions{$source_session}->[SS_CHILDREN]->{$session});

      }

      # Add the new session to its parent's children.
      $kr_sessions{$source_session}->[SS_CHILDREN]->{$session} = $session;
      ses_refcount_inc($source_session);
    }

    # Select event.  Clean up the vectors ahead of time so that
    # reusing filenos isn't so damned painful.

    elsif ($type & ET_SELECT) {

      # Decrement the event count by handle/vector.  -><- Assumes the
      # format for a select event, which may change later.

      my ($handle, $vector) = @$etc;
      my $fileno = fileno($handle);

      if (exists $kr_filenos{$fileno}) {
        my $kr_fno_vec  = $kr_filenos{$fileno}->[$vector];

        if (TRACE_SELECT) {
          warn( "--- decrementing event count in vector ($vector) ",
                "for fileno (", $fileno, ") from count (",
                $kr_fno_vec->[FVC_EV_COUNT], ")"
              );
        }

        # Select events are one-shot, so reset the filehandle watcher
        # after this event was dispatched.

        unless (--$kr_fno_vec->[FVC_EV_COUNT]) {
          if ($kr_fno_vec->[FVC_ST_REQUEST] & HS_PAUSED) {
            loop_pause_filehandle_watcher($kr_fno_vec, $handle, $vector);
          }
          elsif ($kr_fno_vec->[FVC_ST_REQUEST] & HS_RUNNING) {
            loop_resume_filehandle_watcher($kr_fno_vec, $handle, $vector);
          }
          else {
            die "internal consistency error";
          }
        }
        elsif ($kr_fno_vec->[FVC_EV_COUNT] < 0) {
          die "handle event count went below zero";
        }
      }
    }

    # Some sessions don't do anything in _start and expect their
    # creators to provide a start-up event.  This means we can't
    # &_collect_garbage at _start time.  Instead, we post a
    # garbage-collect event at start time, and &_collect_garbage at
    # delivery time.  This gives the session's creator time to do
    # things with it before we reap it.

    elsif ($type & ET_GC) {
      $self->collect_garbage($session);
      return 0;
    }

    # A session's about to stop.  Notify its parents and children of
    # the impending change in their relationships.  Incidental _stop
    # events are handled before the dispatch.

    elsif ($type & ET_STOP) {

      # Tell child sessions that they have a new parent (the departing
      # session's parent).  Tell the departing session's parent that
      # it has new child sessions.

      my $parent   = $kr_sessions{$session}->[SS_PARENT];
      my @children = values %{$kr_sessions{$session}->[SS_CHILDREN]};
      foreach my $child (@children) {
        $self->_dispatch_event
          ( $parent, $self,
            EN_CHILD, ET_CHILD, [ CHILD_GAIN, $child ],
            time(), $file, $line, undef
          );
        $self->_dispatch_event
          ( $child, $self,
            EN_PARENT, ET_PARENT,
            [ $kr_sessions{$child}->[SS_PARENT], $parent, ],
            time(), $file, $line, undef
          );
      }

      # Tell the departing session's parent that the departing session
      # is departing.
      if (defined $parent) {
        $self->_dispatch_event
          ( $parent, $self,
            EN_CHILD, ET_CHILD, [ CHILD_LOSE, $session ],
            time(), $file, $line, undef
          );
      }
    }

    # Preprocess signals.  This is where _signal is translated into
    # its registered handler's event name, if there is one.

    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];

      TRACE_SIGNALS and
        warn( "!!! dispatching ET_SIGNAL ($signal) to session ",
              $session->ID, "\n"
            );

      # Step 0: Reset per-signal structures.

      undef $kr_signal_total_handled;
      $kr_signal_type = $_signal_types{$signal} || SIGTYPE_BENIGN;
      undef @kr_signaled_sessions;

      # Step 1: Propagate the signal to sessions that are watching it.

      if (exists $kr_signals{$signal}) {
        while (my ($session, $event) = each(%{$kr_signals{$signal}})) {
          my $session_ref = $kr_sessions{$session}->[SS_SESSION];

          TRACE_SIGNALS and
            warn( "!!! propagating explicit signal $event ($signal) ",
                  "to session ", $session_ref->ID, "\n"
                );

          $self->_dispatch_event
            ( $session_ref, $self,
              $event, ET_SIGNAL_EXPLICIT, $etc,
              time(), $file, $line, undef
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
      my @children = values %{$kr_sessions{$session}->[SS_CHILDREN]};
      foreach (@children) {

        TRACE_SIGNALS and
          warn( "!!! propagating compatible signal ($signal) to session ",
                $_->ID, "\n"
              );

        $self->_dispatch_event
          ( $_, $self,
            $event, ET_SIGNAL_COMPATIBLE, $etc,
            time(), $file, $line, undef
          );

        TRACE_SIGNALS and
          warn "(!) propagated to $_ (", $_->ID, ")";
      }

      # If this session already received a signal in step 1, then
      # ignore dispatching it again in this step.  This uses a
      # two-step exists so that the longer one does not autovivify
      # keys in the shorter one.
      return if ( ($type & ET_SIGNAL_COMPATIBLE) and
                  exists($kr_signals{$signal}) and
                  exists($kr_signals{$signal}->{$session})
                );
    }
  }

  # The destination session doesn't exist.  This indicates sloppy
  # programming.

  unless (exists $kr_sessions{$session}) {

    if (TRACE_EVENTS) {
      warn ">>> discarding $event to nonexistent ", sid($session), "\n";
    }

    return;
  }

  if (TRACE_EVENTS) {
    warn ">>> dispatching $event to $session ", sid($session), "\n";
    if ($event eq EN_SIGNAL) {
      warn ">>>     signal($etc->[0])\n";
    }
  }

  # Prepare to call the appropriate handler.  Push the current active
  # session on Perl's call stack.
  my $hold_active_session = $kr_active_session;
  $kr_active_session = $session;

  # Clear the implicit/explicit signal handler flags for this event
  # dispatch.  We'll use them afterward to carp at the user if they
  # handled something implicitly but not explicitly.

  undef $kr_signal_handled_implicitly;
  undef $kr_signal_handled_explicitly;

  # Dispatch the event, at long last.
  my $return =
    $session->_invoke_state($source_session, $event, $etc, $file, $line);

  # Stringify the handler's return value if it belongs in the POE
  # namespace.  $return's scope exists beyond the post-dispatch
  # processing, which includes POE's garbage collection.  The scope
  # bleed was known to break determinism in surprising ways.

  if (defined $return) {
    if (substr(ref($return), 0, 5) eq 'POE::') {
      $return = "$return";
    }
  }
  else {
    $return = '';
  }

  # Pop the active session, now that it's not active anymore.
  $kr_active_session = $hold_active_session;

  if (TRACE_EVENTS) {
    warn "<<< ", sid($session), " -> $event returns ($return)\n";
  }

  # Post-dispatch processing.  This is a user event (but not a call),
  # so garbage collect it.  Also garbage collect the sender.

  if ($type & ET_USER) {
    $self->collect_garbage($session);
    $self->collect_garbage($source_session);
  }

  # A new session has started.  Tell its parent.  Incidental _start
  # events are fired after the dispatch.  Garbage collection is
  # delayed until ET_GC.

  if ($type & ET_START) {
    $self->_dispatch_event
      ( $kr_sessions{$session}->[SS_PARENT], $self,
        EN_CHILD, ET_CHILD, [ CHILD_CREATE, $session, $return ],
        time(), $file, $line, undef
      );
  }

  # This session has stopped.  Clean up after it.  There's no
  # garbage collection necessary since the session's stopped.

  elsif ($type & ET_STOP) {

    # Remove the departing session from its parent.

    my $parent = $kr_sessions{$session}->[SS_PARENT];
    if (defined $parent) {

      if (ASSERT_RELATIONS) {
        die sid($session), " is its own parent\a" if ($session == $parent);
        die sid($session), " is not a child of ", sid($parent), "\a"
          unless ( ($session == $parent) or
                   exists($kr_sessions{$parent}->[SS_CHILDREN]->{$session})
                 );
      }

      delete $kr_sessions{$parent}->[SS_CHILDREN]->{$session};
      ses_refcount_dec($parent);
    }

    # Give the departing session's children to its parent.

    my @children = values %{$kr_sessions{$session}->[SS_CHILDREN]};
    foreach (@children) {

      if (ASSERT_RELATIONS) {
        die sid($_), " is already a child of ", sid($parent), "\a"
          if (exists $kr_sessions{$parent}->[SS_CHILDREN]->{$_});
      }

      $kr_sessions{$_}->[SS_PARENT] = $parent;
      if (defined $parent) {
        $kr_sessions{$parent}->[SS_CHILDREN]->{$_} = $_;
        ses_refcount_inc($parent)
      }

      delete $kr_sessions{$session}->[SS_CHILDREN]->{$_};
      ses_refcount_dec($session);
    }

    # Free any signals that the departing session allocated.

    my @signals = keys %{$kr_sessions{$session}->[SS_SIGNALS]};
    foreach (@signals) {
      sig_remove($session, $_);
    }

    # Close any selects that the session still has open.  -><- This is
    # heavy handed; it does work it doesn't need to do.  There must be
    # a better way.

    my @handles = values %{$kr_sessions{$session}->[SS_HANDLES]};
    foreach (@handles) {
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_RD);
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_WR);
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_EX);
    }

    # Free any events that the departing session has in its queue.
    # Also free the events this session has posted.

    my $index = @kr_events;
    while ( $index-- &&
            ( $kr_sessions{$session}->[SS_EVCOUNT]
              or $kr_sessions{$session}->[SS_POST_COUNT]
            )
          ) {
      if ( $kr_events[$index]->[ST_SESSION] == $session
           or $kr_events[$index]->[ST_SOURCE]  == $session
         ) {
        ses_refcount_dec2($kr_events[$index]->[ST_SESSION], SS_EVCOUNT);
        ses_refcount_dec2($kr_events[$index]->[ST_SOURCE], SS_POST_COUNT);
        my $removed_event = splice(@kr_events, $index, 1);
        delete $kr_event_ids{$removed_event->[ST_SEQ]};
      }
    }

    # Close any lingering extra references.
    my @extra_refs = keys %{$kr_sessions{$session}->[SS_EXTRA_REFS]};
    foreach (@extra_refs) {
      remove_extra_reference($session, $_);
    }

    # Release any aliases still registered to the session.

    my @aliases = keys %{$kr_sessions{$session}->[SS_ALIASES]};
    foreach (@aliases) {
      remove_alias($session, $_);
    }

    # Clear the session ID.  The undef part is completely gratuitous;
    # I don't know why I put it there.  -><- The defined test is a
    # kludge; it appears to be undefined when running in Tk mode.

    delete $kr_session_ids{$kr_sessions{$session}->[SS_ID]}
      if defined $kr_sessions{$session}->[SS_ID];
    $kr_sessions{$session}->[SS_ID] = undef;

    # And finally, check all the structures for leakage.  POE's pretty
    # complex internally, so this is a happy fun check.

    if (ASSERT_GARBAGE) {
      my $errors = 0;

      if (my $leaked = $kr_sessions{$session}->[SS_REFCOUNT]) {
        warn sid($session), " has a refcount leak: $leaked\a\n";
        $self->trace_gc_refcount($session);
        $errors++;
      }

      foreach my $l (sort keys %{$kr_sessions{$session}->[SS_EXTRA_REFS]}) {
        my $count = $kr_sessions{$session}->[SS_EXTRA_REFS]->{$l};
        if ($count) {
          warn( sid($session), " leaked an extra reference: ",
                "(tag=$l) (count=$count)\a\n"
              );
          $errors++;
        }
      }

      my @session_hashes = (SS_CHILDREN, SS_HANDLES, SS_SIGNALS, SS_ALIASES);
      foreach my $ses_offset (@session_hashes) {
        if (my $leaked = keys(%{$kr_sessions{$session}->[$ses_offset]})) {
          warn sid($session), " leaked $leaked (offset $ses_offset)\a\n";
          $errors++;
        }
      }

      die "\a\n" if ($errors);
    }

    # Remove the session's structure from the kernel's structure.
    delete $kr_sessions{$session};

    # See if the parent should leave, too.
    if (defined $parent) {
      $self->collect_garbage($parent);
    }

    # Finally, if there are no more sessions, stop the main loop.
    unless (keys %kr_sessions) {
      loop_halt();
    }
  }

  # Step 3: Check for death by terminal signal.

  elsif ($type & (ET_SIGNAL | ET_SIGNAL_EXPLICIT | ET_SIGNAL_COMPATIBLE)) {
    push @kr_signaled_sessions, $session;
    $kr_signal_total_handled += !!$return;
    $kr_signal_handled_implicitly += !!$return;

    unless ($kr_signal_handled_explicitly) {
      if ($kr_signal_handled_implicitly) {
        # -><- DEPRECATION WARNING GOES HERE
        # warn( { % ssid % } . " implicitly handled SIG$etc->[0]\n" );
      }
    }

    if ($type & ET_SIGNAL) {
      if ( ($kr_signal_type & SIGTYPE_NONMASKABLE) or
           ( $kr_signal_type & SIGTYPE_TERMINAL and !$kr_signal_total_handled )
         ) {
        foreach my $dead_session (@kr_signaled_sessions) {
          next unless exists $kr_sessions{$dead_session};
          TRACE_SIGNALS and
            warn( "!!! freeing signaled session ", $dead_session->ID, "\n" );
          $self->session_free($dead_session);
        }
      }
      else {
        foreach my $dead_session (@kr_signaled_sessions) {
          TRACE_SIGNALS and
            warn( "!!! garbage testing signaled ", $dead_session->ID, "\n" );
          $self->collect_garbage($dead_session);
        }
      }
    }
  }

  # It's an alarm being dispatched.

  elsif ($type & ET_ALARM) {
    $self->collect_garbage($session);
  }

  # It's a select being dispatched.
  elsif ($type & ET_SELECT) {
    $self->collect_garbage($session);
  }

  # Return what the handler did.  This is used for call().
  $return;
}

#------------------------------------------------------------------------------
# POE's main loop!  Now with Tk and Event support!

# Do pre-run startup.

sub _initialize_kernel_session {
  # Some personalities allow us to set up static watchers and
  # start/stop them as necessary.  This initializes those static
  # watchers.  This also starts main windows where applicable.
  loop_initialize($poe_kernel);

  # The kernel is a session, sort of.
  $kr_active_session = $poe_kernel;
  $kr_sessions{$poe_kernel} =
    [ $poe_kernel,                    # SS_SESSION
      0,                              # SS_REFCOUNT
      0,                              # SS_EVCOUNT
      undef,                          # SS_PARENT
      { },                            # SS_CHILDREN
      { },                            # SS_HANDLES
      { },                            # SS_SIGNALS
      { },                            # SS_ALIASES
      { },                            # SS_PROCESSES
      $poe_kernel->[KR_ID],           # SS_ID
      { },                            # SS_EXTRA_REFS
      0,                              # SS_POST_COUNT
    ];
}

sub _initialize_kernel_signals {
  # Register all known signal handlers, except the troublesome ones.
  foreach my $signal (keys(%SIG)) {
    # Some signals aren't real, and the act of setting handlers for
    # them can have strange, even fatal side effects.
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

    # Don't watch CHLD or CLD if we're in Apache.
    next if $signal =~ /^CH?LD$/ and exists $INC{'Apache.pm'};

    # Pass a signal to the loop module, which may or may not watch it
    # depending on its own criteria.
    loop_watch_signal($signal);
  }
}

# Do post-run cleanup.

sub finalize_kernel {

  # Disable signal watching since there's now no place for them to go.
  foreach my $signal (keys %SIG) {
    loop_ignore_signal($signal);
  }

  # The main loop is done, no matter which event library ran it.
  # Let's make sure POE isn't leaking things.

  if (ASSERT_GARBAGE) {
    my %kernel_arrays =
      ( kr_events => \@kr_events
      );

    while (my ($array_name, $array_ref) = each(%kernel_arrays)) {
      if (my $leaked = @$array_ref) {
        warn "*** KERNEL ARRAY  LEAK: $array_name = $leaked items\a\n";
        warn "\t(@$array_ref)\n";
      }
    }

    my %kernel_hashes =
      ( kr_sessions     => \%kr_sessions,
        kr_signals      => \%kr_signals,
        kr_aliases      => \%kr_aliases,
        kr_session_ids  => \%kr_session_ids,
        kr_event_ids    => \%kr_event_ids,
        kr_filenos      => \%kr_filenos,
      );

    while (my ($hash_name, $hash_ref) = each(%kernel_hashes)) {
      if (my $leaked = keys %$hash_ref) {
        warn "*** KERNEL HASH   LEAK: $hash_name = $leaked items\a\n";
        foreach my $key (keys %$hash_ref) {
          my $warning = "\t$key";
          my $value = $hash_ref->{$key};
          if (ref($value) eq 'HASH') {
            $warning .= ": (" . join("; ", keys %$value) . ")";
          }
          elsif (ref($value) eq 'ARRAY') {
            $warning .= ": (" . join("; ", @$value) . ")";
          }
          else {
            $warning .= ": $value";
          }
          warn $warning, "\n";
        }
      }
    }
  }

  loop_finalize();

  if (TRACE_PROFILE) {
    print STDERR ',----- Event Profile ' , ('-' x 53), ",\n";
    foreach (sort keys %profile) {
      printf STDERR "| %60.60s %10d |\n", $_, $profile{$_};
    }
    print STDERR '`', ('-' x 73), "'\n";
  }

  # And at the very end, rebuild the Kernel session JUST IN CASE
  # someone wants to re-enter run() after it's returned.  It must be
  # done here because otherwise new sessions won't have a Kernel lying
  # around to be their parent.
  _initialize_kernel_session();
}

sub run_one_timeslice {
  my $self = shift;
  return undef unless %kr_sessions;
  loop_do_timeslice();
  unless (%kr_sessions) {
    finalize_kernel();
    $kr_run_warning |= KR_RUN_DONE;
  }
}

sub run {
  # So run() can be called as a class method.
  my $self = $poe_kernel;

  # If we already returned, then we must reinitialize.  This is so
  # $poe_kernel->run() will work correctly more than once.
  if ($kr_run_warning & KR_RUN_DONE) {
    $kr_run_warning &= ~KR_RUN_DONE;
    _initialize_kernel_signals();
  }

  # Flag that run() was called.
  $kr_run_warning |= KR_RUN_CALLED;

  loop_run();

  # Clean up afterwards.
  finalize_kernel();
  $kr_run_warning |= KR_RUN_DONE;
}

#------------------------------------------------------------------------------

sub DESTROY {
  # Destroy all sessions.  This will cascade destruction to all
  # resources.  It's taken care of by Perl's own garbage collection.
  # For completeness, I suppose a copy of POE::Kernel->run's leak
  # detection could be included here.

  warn "POE::Kernel's run() method was never called.\n"
    if ( ($kr_run_warning & KR_RUN_SESSION) and not
         ($kr_run_warning & KR_RUN_CALLED)
       );
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

          $self->_enqueue_event
            ( $self, $self,
              EN_SIGNAL, ET_SIGNAL, [ 'CHLD', $pid, $? ],
              time(), __FILE__, __LINE__
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

      die "internal consistency error: waitpid returned $pid" if $pid != -1;

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
    loop_resume_watching_child_signals();
  }

  # A signal was posted.  Because signals propagate depth-first, this
  # _invoke_state is called last in the dispatch.  If the signal was
  # SIGIDLE, then post a SIGZOMBIE if the main queue is still idle.

  elsif ($event eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (@kr_events > 1 or scalar(keys %kr_filenos)) {
        $self->_enqueue_event
          ( $self, $self,
            EN_SIGNAL, ET_SIGNAL, [ 'ZOMBIE' ],
            time(), __FILE__, __LINE__
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

  if (ASSERT_RELATIONS) {
    die sid($session), " already exists\a"
      if (exists $kr_sessions{$session});
  }

  # Register that a session was created.
  $kr_run_warning |= KR_RUN_SESSION;

  $self->_dispatch_event
    ( $session, $kr_active_session,
      EN_START, ET_START, \@args,
      time(), __FILE__, __LINE__, undef
    );
  $self->_enqueue_event
    ( $session, $kr_active_session,
      EN_GC, ET_GC, [],
      time(), __FILE__, __LINE__
    );
}

# Dispatch _stop to a session, removing it from the kernel's data
# structures as a side effect.

sub session_free {
  my ($self, $session) = @_;

  TRACE_GARBAGE and warn "freeing session $session";

  if (ASSERT_RELATIONS) {
    die sid($session), " doesn't exist\a"
      unless (exists $kr_sessions{$session});
  }

  $self->_dispatch_event
    ( $session, $kr_active_session,
      EN_STOP, ET_STOP, [],
      time(), __FILE__, __LINE__, undef
    );
}

# Detach a session from its parent.  This breaks the parent/child
# relationship between the current session and its parent.  Basically,
# the current session is given to the Kernel session.  Unlike with
# _stop, the current session's children follow their parent.

sub detach_myself {
  my $self = shift;

  # Can't detach from the kernel.
  if ($kr_sessions{$kr_active_session}->[SS_PARENT] == $poe_kernel) {
    $! = EPERM;
    return;
  }

  my $old_parent = $kr_sessions{$kr_active_session}->[SS_PARENT];

  # Tell the old parent session that the child is departing.
  $self->_dispatch_event
    ( $old_parent, $self,
      EN_CHILD, ET_CHILD, [ CHILD_LOSE, $kr_active_session ],
      time(), (caller)[1,2], undef
    );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the current session that its parentage is changing.
  $self->_dispatch_event
    ( $kr_active_session, $self,
      EN_PARENT, ET_PARENT, [ $old_parent, $poe_kernel ],
      time(), (caller)[1,2], undef
    );

  # Remove the current session from its old parent.
  delete $kr_sessions{$old_parent}->[SS_CHILDREN]->{$kr_active_session};
  ses_refcount_dec($old_parent);

  # Change the current session's parent to the kernel.
  $kr_sessions{$kr_active_session}->[SS_PARENT] = $poe_kernel;

  # Add the current session to the kernel's children.
  $kr_sessions{$poe_kernel}->[SS_CHILDREN]->{$kr_active_session} =
    $kr_active_session;
  ses_refcount_inc($poe_kernel);

  # Success!
  return 1;
}

# Detach a child from this, the parent.  The session being detached
# must be a child of the current session.

sub detach_child {
  my ($self, $child) = @_;

  my $child_session = _alias_resolve($child);
  unless (defined $child_session) {
    explain_resolve_failure($child);
    return;
  }

  # Can't detach if it belongs to the kernel.
  if ($kr_active_session == $poe_kernel) {
    $! = EPERM;
    return;
  }

  # Can't detach if it's not a child of the current session.
  unless
    (exists $kr_sessions{$kr_active_session}->[SS_CHILDREN]->{$child_session})
    {
      $! = EPERM;
      return;
    }

  # Tell the current session that the child is departing.
  $self->_dispatch_event
    ( $kr_active_session, $self,
      EN_CHILD, ET_CHILD, [ CHILD_LOSE, $child_session ],
      time(), (caller)[1,2], undef
    );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the child session that its parentage is changing.
  $self->_dispatch_event
    ( $child_session, $self,
      EN_PARENT, ET_PARENT, [ $kr_active_session, $poe_kernel ],
      time(), (caller)[1,2], undef
    );

  # Remove the child session from its old parent (the current one).
  delete $kr_sessions{$kr_active_session}->[SS_CHILDREN]->{$child_session};
  ses_refcount_dec($kr_active_session);

  # Change the child session's parent to the kernel.
  $kr_sessions{$child_session}->[SS_PARENT] = $poe_kernel;

  # Add the child session to the kernel's children.
  $kr_sessions{$poe_kernel}->[SS_CHILDREN]->{$child_session} = $child_session;
  ses_refcount_inc($poe_kernel);

  # Success!
  return 1;
}

# Debugging subs for reference count checks.

sub trace_gc_refcount {
  my ($self, $session) = @_;

  my ($package, $file, $line) = caller;
  warn "tracing gc refcount from $file at $line\n";

  my $ss = $kr_sessions{$session};
  warn "+----- GC test for ", sid($session), " ($session) -----\n";
  warn "| total refcnt  : $ss->[SS_REFCOUNT]\n";
  warn "| event count   : $ss->[SS_EVCOUNT]\n";
  warn "| post count    : $ss->[SS_POST_COUNT]\n";
  warn "| child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n";
  warn "| handles in use: ", scalar(keys(%{$ss->[SS_HANDLES]})), "\n";
  warn "| aliases in use: ", scalar(keys(%{$ss->[SS_ALIASES]})), "\n";
  warn "| extra refs    : ", scalar(keys(%{$ss->[SS_EXTRA_REFS]})), "\n";
  warn "+---------------------------------------------------\n";
  warn " ...";
  unless ($ss->[SS_REFCOUNT]) {
    warn "| ", sid($session), " is garbage; recycling it...\n";
    warn "+---------------------------------------------------\n";
    warn " ...";
  }
}

sub assert_gc_refcount {
  my ($self, $session) = @_;
  my $ss = $kr_sessions{$session};

  # Calculate the total reference count based on the number of
  # discrete references kept.

  my $calc_ref =
    ( $ss->[SS_EVCOUNT] +
      $ss->[SS_POST_COUNT] +
      scalar(keys(%{$ss->[SS_CHILDREN]})) +
      scalar(keys(%{$ss->[SS_HANDLES]})) +
      scalar(keys(%{$ss->[SS_EXTRA_REFS]})) +
      scalar(keys(%{$ss->[SS_ALIASES]}))
    );

  # The calculated reference count really ought to match the one POE's
  # been keeping track of all along.

  die sid($session), " has a reference count inconsistency\n"
    if $calc_ref != $ss->[SS_REFCOUNT];

  # Compare held handles against reference counts for them.

  foreach (values %{$ss->[SS_HANDLES]}) {
    $calc_ref = $_->[SH_VECCOUNT]->[VEC_RD] +
      $_->[SH_VECCOUNT]->[VEC_WR] + $_->[SH_VECCOUNT]->[VEC_EX];

    die sid($session), " has a handle reference count inconsistency\n"
      if $calc_ref != $_->[SH_REFCOUNT];
  }
}

sub get_active_session {
  my $self = shift;
  return $kr_active_session;
}

#==============================================================================
# EVENTS
#==============================================================================

my $queue_seqnum = 0;

sub _enqueue_event {
  my ( $self, $session, $source_session, $event, $type, $etc, $time,
       $file, $line
     ) = @_;

  if (TRACE_EVENTS) {
    warn( "}}} enqueuing event '$event' from session ", $source_session->ID,
          " to ", sid($session), " at $time"
        );
  }

  if (exists $kr_sessions{$session}) {

    # This is awkward, but faster than enumerating the fields
    # individually.
    my $event_to_enqueue = [ @_[1..8], ++$queue_seqnum ];

    # Special case: No events in the queue.  Put the new event in the
    # queue, and resume watching time.
    unless (@kr_events) {
      $kr_events[0] = $event_to_enqueue;
      loop_resume_time_watcher($kr_events[0]->[ST_TIME]);
    }

    # Special case: The new event belongs at the end of the queue.
    elsif ($time >= $kr_events[-1]->[ST_TIME]) {
      push @kr_events, $event_to_enqueue;
    }

    # Special case: New event comes before earliest event.  Since
    # there is an active time watcher, it must be reset.
    elsif ($time < $kr_events[0]->[ST_TIME]) {
      unshift @kr_events, $event_to_enqueue;
      loop_reset_time_watcher($kr_events[0]->[ST_TIME]);
    }

    # Special case: If there are only two events in the queue, and we
    # failed the last two tests, the new event goes between them.
    elsif (@kr_events == 2) {
      splice @kr_events, 1, 0, $event_to_enqueue;
    }

    # Small queue.  Perform a reverse linear search on the assumption
    # that (a) a linear search is fast enough on small queues; and (b)
    # most events will be posted for "now" or some future time, which
    # tends to be towards the end of the queue.
    elsif (@kr_events < LARGE_QUEUE_SIZE) {
      my $index = @kr_events;
      $index--
        while ( $index and
                $time < $kr_events[$index-1]->[ST_TIME]
              );
      splice @kr_events, $index, 0, $event_to_enqueue;
    }

    # And finally, we have this large queue, and the program has
    # already wasted enough time.  -><- It would be neat for POE to
    # determine the break-even point between "large" and "small" event
    # queues at start-up and tune itself accordingly.
    else {
      my $upper = @kr_events - 1;
      my $lower = 0;
      while ('true') {
        my $midpoint = ($upper + $lower) >> 1;

        # Upper and lower bounds crossed.  No match; insert at the
        # lower bound point.
        if ($upper < $lower) {
          splice @kr_events, $lower, 0, $event_to_enqueue;
          last;
        }

        # The key at the midpoint is too high.  The element just below
        # the midpoint becomes the new upper bound.
        if ($time < $kr_events[$midpoint]->[ST_TIME]) {
          $upper = $midpoint - 1;
          next;
        }

        # The key at the midpoint is too low.  The element just above
        # the midpoint becomes the new lower bound.
        if ($time > $kr_events[$midpoint]->[ST_TIME]) {
          $lower = $midpoint + 1;
          next;
        }

        # The key matches the one at the midpoint.  Scan towards
        # higher keys until the midpoint points to an element with a
        # higher key.  Insert the new event before it.
        $midpoint++
          while ( ($midpoint < @kr_events)
                  and ($time == $kr_events[$midpoint]->[ST_TIME])
                );
        splice @kr_events, $midpoint, 0, $event_to_enqueue;
        last;
      }
    }

    # Manage reference counts.
    ses_refcount_inc2($session, SS_EVCOUNT);
    ses_refcount_inc2($source_session, SS_POST_COUNT);

    # Users know timers by their IDs; the queue knows them by their
    # times.  Map the ID to the time so we can binary search the queue
    # for events that will be removed or altered later.
    my $new_event_id = $event_to_enqueue->[ST_SEQ];
    $kr_event_ids{$new_event_id} = $time;

    # Return the new event ID.  Man, this rocks.  I forgot POE was
    # maintaining event sequence numbers.
    return $new_event_id;
  }

  # This function already has returned if everything went well.
  warn ">>>>> ", join('; ', keys(%kr_sessions)), " <<<<<\n";
  croak "can't enqueue event($event) for nonexistent session($session)\a\n";
}

#------------------------------------------------------------------------------
# Post an event to the queue.

sub post {
  my ($self, $destination, $event_name, @etc) = @_;

  ASSERT_USAGE and do {
    croak "destination is undefined in post()" unless defined $destination;
    croak "event is undefined in post()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by posting it"
        ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = _alias_resolve($destination);
  unless (defined $session) {
    explain_resolve_failure($destination);
    return;
  }

  # Enqueue the event for "now", which simulates FIFO in our
  # time-ordered queue.

  $self->_enqueue_event
    ( $session, $kr_active_session,
      $event_name, ET_USER, \@etc,
      time(), (caller)[1,2]
    );
  return 1;
}

#------------------------------------------------------------------------------
# Post an event to the queue for the current session.

sub yield {
  my ($self, $event_name, @etc) = @_;

  ASSERT_USAGE and do {
    croak "event name is undefined in yield()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by yielding it"
        ) if exists $poes_own_events{$event_name};
  };

  $self->_enqueue_event
    ( $kr_active_session, $kr_active_session,
      $event_name, ET_USER, \@etc,
      time(), (caller)[1,2]
    );

  undef;
}

#------------------------------------------------------------------------------
# Call an event handler directly.

sub call {
  my ($self, $destination, $event_name, @etc) = @_;

  ASSERT_USAGE and do {
    croak "destination is undefined in call()" unless defined $destination;
    croak "event is undefined in call()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by calling it"
        ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = _alias_resolve($destination);
  unless (defined $session) {
    explain_resolve_failure($destination);
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
        time(), (caller)[1,2], undef
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
  my ($self) = @_;
  my @pending_alarms;

  my $alarm_count = $kr_sessions{$kr_active_session}->[SS_EVCOUNT];

  foreach my $alarm (@kr_events) {
    last unless $alarm_count;
    next unless $alarm->[ST_SESSION] == $kr_active_session;
    next unless $alarm->[ST_TYPE] & ET_ALARM;
    push @pending_alarms, $alarm->[ST_NAME];
    $alarm_count--;
  }

  @pending_alarms;
}

#==============================================================================
# DELAYED EVENTS
#==============================================================================

sub alarm {
  my ($self, $event_name, $time, @etc) = @_;

  ASSERT_USAGE and do {
    croak "event name is undefined in alarm()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting an alarm for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name) {
    explain_return("invalid parameter to alarm() call");
    return EINVAL;
  }

  my $index = @kr_events;
  while ($index--) {
    if ( ($kr_events[$index]->[ST_TYPE] & ET_ALARM) &&
         ($kr_events[$index]->[ST_SESSION] == $kr_active_session) &&
         ($kr_events[$index]->[ST_NAME] eq $event_name)
    ) {
      ses_refcount_dec2($kr_active_session, SS_EVCOUNT);
      ses_refcount_dec2($kr_active_session, SS_POST_COUNT);
      my $removed_alarm = splice(@kr_events, $index, 1);
      delete $kr_event_ids{$removed_alarm->[ST_SEQ]};
    }
  }

  # Add the new alarm if it includes a time.  Calling _enqueue_event
  # directly is faster than calling alarm_set to enqueue it.
  if (defined $time) {
    $self->_enqueue_event
      ( $kr_active_session, $kr_active_session,
        $event_name, ET_ALARM, [ @etc ],
        $time, (caller)[1,2]
      );
  }
  else {
    # The event queue has become empty?  Stop the time watcher.
    unless (@kr_events) {
      loop_pause_time_watcher();
    }
  }

  return 0;
}

# Add an alarm without clobbering previous alarms of the same name.
sub alarm_add {
  my ($self, $event_name, $time, @etc) = @_;

  ASSERT_USAGE and do {
    croak "undefined event name in alarm_add()" unless defined $event_name;
    croak "undefined time in alarm_add()" unless defined $time;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by adding an alarm for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name and defined $time) {
    explain_return("invalid parameter to alarm_add() call");
    return EINVAL;
  }

  $self->_enqueue_event
    ( $kr_active_session, $kr_active_session,
      $event_name, ET_ALARM, [ @etc ],
      $time, (caller)[1,2]
    );

  return 0;
}

# Add a delay, which is just an alarm relative to the current time.
sub delay {
  my ($self, $event_name, $delay, @etc) = @_;

  ASSERT_USAGE and do {
    croak "undefined event name in delay()" unless defined $event_name;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a delay for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name) {
    explain_return("invalid parameter to delay() call");
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
    croak "undefined event name in delay_add()" unless defined $event_name;
    croak "undefined time in delay_add()" unless defined $delay;
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by adding a delay for it"
        ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name and defined $delay) {
    explain_return("invalid parameter to delay_add() call");
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
    explain_usage("undefined event name in alarm_set()");
    $! = EINVAL;
    return;
  }

  unless (defined $time) {
    explain_usage("undefined time in alarm_set()");
    $! = EINVAL;
    return;
  }

  if (ASSERT_USAGE) {
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting an alarm for it"
        ) if exists $poes_own_events{$event_name};
  }

  return $self->_enqueue_event
    ( $kr_active_session, $kr_active_session,
      $event_name, ET_ALARM, [ @etc ],
      $time, (caller)[1,2]
    );
}

# This is an event helper: it finds an event in the queue.  Special
# cases don't count here because we assume the event exists.  It dies
# outright if there's a problem because its parameters have been
# verified good before it's called.  Failure is not an option here.

# A lot of the code here is duplicated in _enqueue_event.

# THIS IS A STATIC FUNCTION!

sub _event_find {
  my ($time, $id) = @_;

  # Small queue.  Find the event with a linear seek on the assumption
  # that the overhead of a binary seek would be more than a linear
  # search at this point.  The actual break-even point is unknown, and
  # it probably varies from system to system.
  if (@kr_events < LARGE_QUEUE_SIZE) {
    my $index = @kr_events;
    while ($index--) {
      return $index if $id == $kr_events[$index]->[ST_SEQ];
    }
    die "internal inconsistency: event should have been found";
  }

  # Use a binary seek to find events in a large queue.

  else {
    my $upper = @kr_events - 1;
    my $lower = 0;
    while ('true') {
      my $midpoint = ($upper + $lower) >> 1;

      # The streams have crossed.  That's bad.
      die "internal inconsistency: event should have been found"
        if $upper < $lower;

      # The key at the midpoint is too high.  The element just below
      # the midpoint becomes the new upper bound.
      if ($time < $kr_events[$midpoint]->[ST_TIME]) {
        $upper = $midpoint - 1;
        next;
      }

      # The key at the midpoint is too low.  The element just above
      # the midpoint becomes the new lower bound.
      if ($time > $kr_events[$midpoint]->[ST_TIME]) {
        $lower = $midpoint + 1;
        next;
      }

      # The key (time) matches the one at the midpoint.  This may be
      # in the middle of a pocket of events with the same time, so
      # we'll have to search back and forth for one with the ID we're
      # looking for.  Unfortunately.
      my $linear_point = $midpoint;
      while ( $linear_point >= 0 and
              $time == $kr_events[$linear_point]->[ST_TIME]
            ) {
        return $linear_point if $kr_events[$linear_point]->[ST_SEQ] == $id;
        $linear_point--;
      }
      $linear_point = $midpoint;
      while ( (++$linear_point < @kr_events) and
              ($time == $kr_events[$linear_point]->[ST_TIME])
            ) {
        return $linear_point if $kr_events[$linear_point]->[ST_SEQ] == $id;
      }

      # If we get this far, then the event hasn't been found.
      die "internal inconsistency: event should have been found";
    }
  }

  die "this message should never be reached";
}

# Remove an alarm by its ID.  -><- Now that alarms and events have
# been recombined, this will remove an event by its ID.  However,
# nothing returns an event ID, so nobody knows what to remove.

sub alarm_remove {
  my ($self, $alarm_id) = @_;

  unless (defined $alarm_id) {
    explain_usage("undefined alarm id in alarm_remove()");
    $! = EINVAL;
    return;
  }

  my $alarm_time = $kr_event_ids{$alarm_id};
  unless (defined $alarm_time) {
    explain_usage("unknown alarm id in alarm_remove()");
    $! = ESRCH;
    return;
  }

  # Find the alarm by time.
  my $alarm_index = _event_find( $alarm_time, $alarm_id );

  # Ensure that the alarm belongs to this session, eh?
  if ($kr_events[$alarm_index]->[ST_SESSION] != $kr_active_session) {
    explain_usage("alarm $alarm_id is not for the session");
    $! = EPERM;
    return;
  }

  my $old_alarm = splice( @kr_events, $alarm_index, 1 );
  ses_refcount_dec2($kr_active_session, SS_EVCOUNT);
  ses_refcount_dec2($kr_active_session, SS_POST_COUNT);
  delete $kr_event_ids{$old_alarm->[ST_SEQ]};

  # In a list context, return the alarm that was removed.  In a scalar
  # context, return a reference to the alarm that was removed.  In a
  # void context, return nothing.  Either way this returns a defined
  # value when someone needs something useful from it.

  return unless defined wantarray;
  return ( @$old_alarm[ST_NAME, ST_TIME], @{$old_alarm->[ST_ARGS]} )
    if wantarray;
  return [ @$old_alarm[ST_NAME, ST_TIME], @{$old_alarm->[ST_ARGS]} ];
}

# Move an alarm to a new time.  This virtually removes the alarm and
# re-adds it somewhere else.

sub alarm_adjust {
  my ($self, $alarm_id, $delta) = @_;

  unless (defined $alarm_id) {
    explain_usage("undefined alarm id in alarm_adjust()");
    $! = EINVAL;
    return;
  }

  unless (defined $delta) {
    explain_usage("undefined alarm delta in alarm_adjust()");
    $! = EINVAL;
    return;
  }

  my $alarm_time = $kr_event_ids{$alarm_id};
  unless (defined $alarm_time) {
    explain_usage("unknown alarm id in alarm_adjust()");
    $! = ESRCH;
    return;
  }

  # Find the alarm by time.
  my $alarm_index = _event_find( $alarm_time, $alarm_id );

  # Ensure that the alarm belongs to this session, eh?
  if ($kr_events[$alarm_index]->[ST_SESSION] != $kr_active_session) {
    explain_usage("alarm $alarm_id is not for the session");
    $! = EPERM;
    return;
  }

  # Nothing to do if the delta is zero.
  return $kr_events[$alarm_index]->[ST_TIME] unless $delta;

  # Remove the old alarm and adjust its time.
  my $old_alarm = splice( @kr_events, $alarm_index, 1 );
  my $new_time = $old_alarm->[ST_TIME] += $delta;
  $kr_event_ids{$alarm_id} = $new_time;

  # Now insert it back.

  # Special case: No events in the queue.  Put the new alarm in the
  # queue, and be done with it.
  unless (@kr_events) {
    $kr_events[0] = $old_alarm;
  }

  # Special case: New event belongs at the end of the queue.  Push
  # it, and be done with it.
  elsif ($new_time >= $kr_events[-1]->[ST_TIME]) {
    push @kr_events, $old_alarm;
  }

  # Special case: New event comes before earliest event.  Unshift
  # it, and be done with it.
  elsif ($new_time < $kr_events[0]->[ST_TIME]) {
    unshift @kr_events, $old_alarm;
  }

  # Special case: Two events in the queue.  The new event enters
  # between them, because it's not before the first one or after the
  # last one.
  elsif (@kr_events == 2) {
    splice @kr_events, 1, 0, $old_alarm;
  }

  # Small queue.  Perform a reverse linear search on the assumption
  # that (a) a linear search is fast enough on small queues; and (b)
  # most events will be posted for "now" or some future time, which
  # tends to be towards the end of the queue.
  elsif ($delta > 0 and (@kr_events - $alarm_index) < LARGE_QUEUE_SIZE) {
    my $index = $alarm_index;
    $index++
      while ( $index < @kr_events and
              $new_time >= $kr_events[$index]->[ST_TIME]
            );
    splice @kr_events, $index, 0, $old_alarm;
  }

  elsif ($delta < 0 and $alarm_index < LARGE_QUEUE_SIZE) {
    my $index = $alarm_index;
    $index--
      while ( $index and
              $new_time < $kr_events[$index-1]->[ST_TIME]
            );
    splice @kr_events, $index, 0, $old_alarm;
  }

  # And finally, we have this large queue, and the program has already
  # wasted enough time.  -><- It would be neat for POE to determine
  # the break-even point between "large" and "small" alarm queues at
  # start-up and tune itself accordingly.
  else {
    my ($upper, $lower);
    if ($delta > 0) {
      $upper = @kr_events - 1;
      $lower = $alarm_index;
    }
    else {
      $upper = $alarm_index;
      $lower = 0;
    }

    while ('true') {
      my $midpoint = ($upper + $lower) >> 1;

      # Upper and lower bounds crossed.  No match; insert at the
      # lower bound point.
      if ($upper < $lower) {
        splice @kr_events, $lower, 0, $old_alarm;
        last;
      }

      # The key at the midpoint is too high.  The element just below
      # the midpoint becomes the new upper bound.
      if ($new_time < $kr_events[$midpoint]->[ST_TIME]) {
        $upper = $midpoint - 1;
        next;
      }

      # The key at the midpoint is too low.  The element just above
      # the midpoint becomes the new lower bound.
      if ($new_time > $kr_events[$midpoint]->[ST_TIME]) {
        $lower = $midpoint + 1;
        next;
      }

      # The key matches the one at the midpoint.  Scan towards
      # higher keys until the midpoint points to an element with a
      # higher key.  Insert the new event before it.
      $midpoint++
        while ( ($midpoint < @kr_events) and
                ($new_time == $kr_events[$midpoint]->[ST_TIME])
              );
      splice @kr_events, $midpoint, 0, $old_alarm;
      last;
    }
  }

  return $new_time;
}

# A convenient function for setting alarms relative to now.  It also
# uses whichever time() POE::Kernel can find, which may be
# Time::HiRes'.

sub delay_set {
  my ($self, $event_name, $seconds, @etc) = @_;

  unless (defined $event_name) {
    explain_usage("undefined event name in delay_set()");
    $! = EINVAL;
    return;
  }

  if (ASSERT_USAGE) {
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a delay for it"
        ) if exists $poes_own_events{$event_name};
  }

  unless (defined $seconds) {
    explain_usage("undefined seconds in delay_set()");
    $! = EINVAL;
    return;
  }

  return $self->_enqueue_event
    ( $kr_active_session, $kr_active_session,
      $event_name, ET_ALARM, [ @etc ],
      time() + $seconds, (caller)[1,2]
    );
}

# Remove all alarms for the current session.

sub alarm_remove_all {
  my $self = shift;
  my @removed;

  # This should never happen, actually.
  croak "unknown session in alarm_remove_all call"
    unless exists $kr_sessions{$kr_active_session};

  # Free every alarm owned by the session.  This code is ripped off
  # from the _stop code to flush everything.

  my $index = @kr_events;
  while ($index-- && $kr_sessions{$kr_active_session}->[SS_EVCOUNT]) {
    if ( $kr_events[$index]->[ST_SESSION] == $kr_active_session and
         $kr_events[$index]->[ST_TYPE] & ET_ALARM
       ) {
      ses_refcount_dec2($kr_active_session, SS_EVCOUNT);
      ses_refcount_dec2($kr_active_session, SS_POST_COUNT);
      my $removed_alarm = splice(@kr_events, $index, 1);
      delete $kr_event_ids{$removed_alarm->[ST_SEQ]};
      push( @removed,
            [ @$removed_alarm[ST_NAME, ST_TIME], @{$removed_alarm->[ST_ARGS]} ]
          );
    }
  }

  return unless defined wantarray;
  return @removed if wantarray;
  return \@removed;
}

#==============================================================================
# SELECTS
#==============================================================================

sub _internal_select {
  my ($self, $session, $handle, $event_name, $select_index) = @_;
  my $fileno = fileno($handle);

  # If an event is included, then we're defining a filehandle watcher.

  if ($event_name) {

    # However, the fileno is not known.  This is a new file.  Create
    # the data structure for it, and prepare the handle for use.

    unless (exists $kr_filenos{$fileno}) {

      if (TRACE_SELECT) {
        warn "!!! adding fileno (", $fileno, ")";
      }

      $kr_filenos{$fileno} =
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

      unless (tied *$handle) {

        # For DOSISH systems like OS/2.  Not entirely harmless: Some
        # tied-filehandle classes don't implement binmode.
        binmode(*$handle);

        # Make the handle stop blocking, the Windows way.
        if (RUNNING_IN_HELL) {
          my $set_it = "1";

          # 126 is FIONBIO (some docs say 0x7F << 16)
          ioctl( $handle,
                 0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
                 $set_it
               ) or die "Can't set the handle non-blocking: $!";
        }

        # Make the handle stop blocking, the POSIX way.
        else {
          my $flags = fcntl($handle, F_GETFL, 0)
            or croak "fcntl($handle, F_GETFL, etc.) fails: $!\n";
          until (fcntl($handle, F_SETFL, $flags | O_NONBLOCK)) {
            croak "fcntl($handle, FSETFL, etc) fails: $!"
              unless $! == EAGAIN or $! == EWOULDBLOCK;
          }
        }
      }

      # Turn off buffering.
      select((select($handle), $| = 1)[0]);
    }

    # Cache some high-level lookups.
    my $kr_fileno  = $kr_filenos{$fileno};
    my $kr_fno_vec = $kr_fileno->[$select_index];

    # The session is already watching this fileno in this mode.

    if (exists $kr_fno_vec->[FVC_SESSIONS]->{$session}) {

      # The session is also watching it by the same handle.  Treat
      # this as a "resume" in this mode.

      if (exists $kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle}) {
        if (TRACE_SELECT) {
          warn( "=== fileno(" . $fileno . ") vector($select_index) " .
                "count($kr_fno_vec->[FVC_EV_COUNT])"
              );
        }
        unless ($kr_fno_vec->[FVC_EV_COUNT]) {
          loop_resume_filehandle_watcher($kr_fno_vec, $handle, $select_index);
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
          $event_name,  # HSS_STATE
        ];

      # Fix reference counts.
      $kr_fileno->[FNO_TOT_REFCOUNT]++;
      $kr_fno_vec->[FVC_REFCOUNT]++;

      # If this is the first time a file is watched in this mode, then
      # have the event loop bridge watch it.
      if ($kr_fno_vec->[FVC_REFCOUNT] == 1) {
        loop_watch_filehandle($kr_fno_vec, $handle, $select_index);
      }
    }

    # SS_HANDLES
    my $kr_session = $kr_sessions{$session};

    # If the session hasn't already been watching the filehandle, then
    # register the filehandle in the session's structure.

    unless (exists $kr_session->[SS_HANDLES]->{$handle}) {
      $kr_session->[SS_HANDLES]->{$handle} = [ $handle, 0, [ 0, 0, 0 ] ];
      ses_refcount_inc($session);
    }

    # Modify the session's handle structure's reference counts, so the
    # session knows it has a reason to live.

    my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
    unless ($ss_handle->[SH_VECCOUNT]->[$select_index]) {
      $ss_handle->[SH_VECCOUNT]->[$select_index]++;
      $ss_handle->[SH_REFCOUNT]++;
    }
  }

  # Remove a select from the kernel, and possibly trigger the
  # session's destruction.

  else {
    # KR_FILENOS

    # Make sure the handle is deregistered with the kernel.

    if (exists $kr_filenos{$fileno}) {
      my $kr_fileno  = $kr_filenos{$fileno};
      my $kr_fno_vec = $kr_fileno->[$select_index];

      # Make sure the handle was registered to the requested session.

      if ( exists($kr_fno_vec->[FVC_SESSIONS]->{$session}) and
           exists($kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle})
         ) {

        # Remove the handle from the kernel's session record.

        my $handle_rec =
          delete $kr_fno_vec->[FVC_SESSIONS]->{$session}->{$handle};

        my $kill_session = $handle_rec->[HSS_SESSION];
        my $kill_event   = $handle_rec->[HSS_STATE];

        # Remove any events destined for that handle.

        my $index = @kr_events;
        while ( $kr_fno_vec->[FVC_EV_COUNT] and
                $index-- and
                $kr_sessions{$kr_active_session}->[SS_EVCOUNT]
              ) {
          next unless ( $kr_events[$index]->[ST_SESSION] == $kill_session and
                        $kr_events[$index]->[ST_NAME]    eq $kill_event
                      );
          ses_refcount_dec2($kr_events[$index]->[ST_SESSION], SS_EVCOUNT);
          ses_refcount_dec2($kr_events[$index]->[ST_SOURCE], SS_POST_COUNT);

          my $removed_event = splice(@kr_events, $index, 1);
          delete $kr_event_ids{$removed_event->[ST_SEQ]};

          $kr_fno_vec->[FVC_EV_COUNT]--;
        }

        # Decrement the handle's reference count.

        $kr_fno_vec->[FVC_REFCOUNT]--;

        if (ASSERT_REFCOUNT) {
          die "fileno vector refcount went below zero"
            if $kr_fno_vec->[FVC_REFCOUNT] < 0;
        }

        # If the "vector" count drops to zero, then stop selecting the
        # handle.

        unless ($kr_fno_vec->[FVC_REFCOUNT]) {
          loop_ignore_filehandle($kr_fno_vec, $handle, $select_index);

          # The session is not watching handles anymore.  Remove the
          # session entirely the fileno structure.
          delete $kr_fno_vec->[FVC_SESSIONS]->{$session}
            unless keys %{$kr_fno_vec->[FVC_SESSIONS]->{$session}};
        }

        # Decrement the kernel record's handle reference count.  If
        # the handle is done being used, then delete it from the
        # kernel's record structure.  This initiates Perl's garbage
        # collection on it, as soon as whatever else in "user space"
        # frees it.

        $kr_fileno->[FNO_TOT_REFCOUNT]--;

        if (ASSERT_REFCOUNT) {
          die "fileno refcount went below zero"
            if $kr_fileno->[FNO_TOT_REFCOUNT] < 0;
        }

        unless ($kr_fileno->[FNO_TOT_REFCOUNT]) {
          if (TRACE_SELECT) {
            warn "!!! deleting fileno (", $fileno, ")";
          }
          delete $kr_filenos{$fileno};
        }
      }
    }

    # SS_HANDLES - Remove the select from the session, assuming there
    # is a session to remove it from.  -><- Key it on fileno?

    my $kr_session = $kr_sessions{$session};
    if (exists $kr_session->[SS_HANDLES]->{$handle}) {

      # Remove it from the session's read, write or expedite vector.

      my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
      if ($ss_handle->[SH_VECCOUNT]->[$select_index]) {

        # Hmm... what is this?  Was POE going to support multiple selects?

        $ss_handle->[SH_VECCOUNT]->[$select_index] = 0;

        # Decrement the reference count, and delete the handle if it's done.

        $ss_handle->[SH_REFCOUNT]--;

        if (ASSERT_REFCOUNT) {
          die if ($ss_handle->[SH_REFCOUNT] < 0);
        }

        unless ($ss_handle->[SH_REFCOUNT]) {
          delete $kr_session->[SS_HANDLES]->{$handle};
          ses_refcount_dec($session);
        }
      }
    }
  }
}

# A higher-level select() that manipulates read, write and expedite
# selects together.

sub select {
  my ($self, $handle, $event_r, $event_w, $event_e) = @_;

  if (ASSERT_USAGE) {
    croak "undefined filehandle in select()" unless defined $handle;
    croak "invalid filehandle in select()" unless defined fileno($handle);
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
    croak "undefined filehandle in select_read()" unless defined $handle;
    croak "invalid filehandle in select_read()" unless defined fileno($handle);
    carp( "The '$event_name' event is one of POE's own.  Its " .
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
    croak "undefined filehandle in select_write()" unless defined $handle;
    croak "invalid filehandle in select_write()"
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
    croak "undefined filehandle in select_expedite()" unless defined $handle;
    croak "invalid filehandle in select_expedite()"
      unless defined fileno($handle);
    carp( "The '$event_name' event is one of POE's own.  Its " .
          "effect cannot be achieved by setting a file watcher to it"
        ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, VEC_EX);
  return 0;
}

# Turn off a handle's write vector bit without doing
# garbage-collection things.
sub select_pause_write {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    croak "undefined filehandle in select_pause_write()"
      unless defined $handle;
    croak "invalid filehandle in select_pause_write()"
      unless defined fileno($handle);
  };

  return 0 unless handle_is_good($handle, VEC_WR);

  # If there are no events in the queue for this handle/mode
  # combination, then we can go ahead and set the actual state now.
  # Otherwise it'll have to wait until the queue empties.

  my $kr_fileno  = $kr_filenos{fileno($handle)};
  my $kr_fno_vec = $kr_fileno->[VEC_WR];
  if (TRACE_SELECT) {
    warn( "=== pause test: fileno(" . fileno($handle) . ") vector(VEC_WR) " .
          "count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  unless ($kr_fno_vec->[FVC_EV_COUNT]) {
    loop_pause_filehandle_watcher($kr_fno_vec, $handle, VEC_WR);
  }

  # Set the requested handle state so it'll be correct when the actual
  # state must be changed to reflect it.

  $kr_fno_vec->[FVC_ST_REQUEST] = HS_PAUSED;

  return 0;
}

# Turn on a handle's write vector bit without doing garbage-collection
# things.
sub select_resume_write {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    croak "undefined filehandle in select_resume_write()"
      unless defined $handle;
    croak "invalid filehandle in select_resume_write()"
      unless defined fileno($handle);
  };

  return 0 unless handle_is_good($handle, VEC_WR);

  # If there are no events in the queue for this handle/mode
  # combination, then we can go ahead and set the actual state now.
  # Otherwise it'll have to wait until the queue empties.

  my $kr_fileno = $kr_filenos{fileno($handle)};
  my $kr_fno_vec = $kr_fileno->[VEC_WR];
  if (TRACE_SELECT) {
    warn( "=== resume test: fileno(" . fileno($handle) . ") vector(VEC_WR) " .
          "count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  unless ($kr_fno_vec->[FVC_EV_COUNT]) {
    loop_resume_filehandle_watcher($kr_fno_vec, $handle, VEC_WR);
  }

  # Set the requested handle state so it'll be correct when the actual
  # state must be changed to reflect it.

  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;

  return 1;
}

# Turn off a handle's read vector bit without doing garbage-collection
# things.
sub select_pause_read {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    croak "undefined filehandle in select_pause_read()"
      unless defined $handle;
    croak "invalid filehandle in select_pause_read()"
      unless defined fileno($handle);
  };

  return 0 unless handle_is_good($handle, VEC_RD);

  # If there are no events in the queue for this handle/mode
  # combination, then we can go ahead and set the actual state now.
  # Otherwise it'll have to wait until the queue empties.

  my $kr_fileno = $kr_filenos{fileno($handle)};
  my $kr_fno_vec = $kr_fileno->[VEC_RD];
  if (TRACE_SELECT) {
    warn( "=== pause test: fileno(" . fileno($handle) . ") vector(VEC_RD) " .
          "count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  unless ($kr_fno_vec->[FVC_EV_COUNT]) {
    loop_pause_filehandle_watcher($kr_fno_vec, $handle, VEC_RD);
  }

  # Correct the requested state so it matches the actual one.

  $kr_fno_vec->[FVC_ST_REQUEST] = HS_PAUSED;

  return 0;
}

# Turn on a handle's read vector bit without doing garbage-collection
# things.
sub select_resume_read {
  my ($self, $handle) = @_;

  ASSERT_USAGE and do {
    croak "undefined filehandle in select_resume_read()"
      unless defined $handle;
    croak "invalid filehandle in select_resume_read()"
      unless defined fileno($handle);
  };

  return 0 unless handle_is_good($handle, VEC_RD);

  # If there are no events in the queue for this handle/mode
  # combination, then we can go ahead and set the actual state now.
  # Otherwise it'll have to wait until the queue empties.

  my $kr_fileno = $kr_filenos{fileno($handle)};
  my $kr_fno_vec = $kr_fileno->[VEC_RD];
  if (TRACE_SELECT) {
    warn( "=== resume test: fileno(" . fileno($handle) . ") vector(VEC_RD) " .
          "count($kr_fno_vec->[FVC_EV_COUNT])"
        );
  }
  unless ($kr_fno_vec->[FVC_EV_COUNT]) {
    loop_resume_filehandle_watcher($kr_fno_vec, $handle, VEC_RD);
  }

  # Set the requested handle state so it'll be correct when the actual
  # state must be changed to reflect it.

  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;

  return 1;
}

#==============================================================================
# ALIASES
#==============================================================================

sub alias_set {
  my ($self, $name) = @_;

  ASSERT_USAGE and do {
    croak "undefined alias in alias_set()" unless defined $name;
  };

  # Don't overwrite another session's alias.
  if (exists $kr_aliases{$name}) {
    if ($kr_aliases{$name} != $kr_active_session) {
      explain_usage("alias is in use by another session");
      return EEXIST;
    }
    return 0;
  }

  $kr_aliases{$name} = $kr_active_session;
  $kr_sessions{$kr_active_session}->[SS_ALIASES]->{$name} = 1;

  ses_refcount_inc($kr_active_session);

  return 0;
}

# Public interface for removing aliases.
sub alias_remove {
  my ($self, $name) = @_;

  ASSERT_USAGE and do {
    croak "undefined alias in alias_remove()" unless defined $name;
  };

  unless (exists $kr_aliases{$name}) {
    explain_usage("alias does not exist");
    return ESRCH;
  }
  if ($kr_aliases{$name} != $kr_active_session) {
    explain_usage("alias does not belong to current session");
    return EPERM;
  }

  remove_alias($kr_active_session, $name);

  return 0;
}

# Resolve an alias into a session.
sub alias_resolve {
  my ($self, $name) = @_;

  ASSERT_USAGE and do {
    croak "undefined alias in alias_resolve()" unless defined $name;
  };

  my $session = _alias_resolve($name);
  unless (defined $session) {
    explain_resolve_failure($name);
    return;
  }

  $session;
}

# List the aliases for a given session.
sub alias_list {
  my ($self, $search_session) = @_;
  my $session;

  # If the search session is defined, then resolve it in case it's an
  # ID or something.
  if (defined $search_session) {
    $session = _alias_resolve($search_session);
    unless (defined $session) {
      explain_resolve_failure($search_session);
      return;
    }
  }

  # Undefined?  Make it the current session by default.
  else {
    $session = $kr_active_session;
  }

  # Return whatever can be found.
  my @alias_list = keys %{$kr_sessions{$session}->[SS_ALIASES]};
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
# moot now that _alias_resolve does it too.  This explicit call will be
# faster, though, so it's kept for things that can benefit from it.

sub ID_id_to_session {
  my ($self, $id) = @_;

  ASSERT_USAGE and do {
    croak "undefined ID in ID_id_to_session()" unless defined $id;
  };

  if (exists $kr_session_ids{$id}) {
    $! = 0;
    return $kr_session_ids{$id};
  }

  explain_return("ID does not exist");
  $! = ESRCH;
  return;
}

# Resolve a session reference to its corresponding ID.

sub ID_session_to_id {
  my ($self, $session) = @_;

  ASSERT_USAGE and do {
    croak "undefined session in ID_session_to_id()" unless defined $session;
  };

  if (exists $kr_sessions{$session}) {
    $! = 0;
    return $kr_sessions{$session}->[SS_ID];
  }

  explain_return("session ($session) does not exist");
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
    croak "undefined session ID in refcount_increment()"
      unless defined $session_id;
    croak "undefined reference count tag in refcount_increment()"
      unless defined $tag;
  };

  my $session = $self->ID_id_to_session( $session_id );
  if (defined $session) {

    # Increment the tag's count for the session.  If this is the first
    # time the tag's been used for the session, then increment the
    # session's reference count as well.

    my $refcount = ++$kr_sessions{$session}->[SS_EXTRA_REFS]->{$tag};

    if (TRACE_REFCOUNT) {
      carp( "+++ ", sid($session), " refcount for tag '$tag' incremented to ",
            $refcount
          );
    }

    if ($refcount == 1) {
      ses_refcount_inc($session);

      if (TRACE_REFCOUNT) {
          carp( "+++ ", sid($session), " refcount for session is at ",
                $kr_sessions{$session}->[SS_REFCOUNT]
             );
      }

      $kr_extra_refs++;

      if (TRACE_REFCOUNT) {
        carp( "+++ session refcounts in kernel: $kr_extra_refs" );
      }

    }

    return $refcount;
  }

  explain_return("session id $session_id does not exist");
  $! = ESRCH;
  return;
}

sub refcount_decrement {
  my ($self, $session_id, $tag) = @_;

  ASSERT_USAGE and do {
    croak "undefined session ID in refcount_decrement()"
      unless defined $session_id;
    croak "undefined reference count tag in refcount_decrement()"
      unless defined $tag;
  };

  my $session = $self->ID_id_to_session( $session_id );
  if (defined $session) {

    # Decrement the tag's count for the session.  If this was the last
    # time the tag's been used for the session, then decrement the
    # session's reference count as well.

    ASSERT_USAGE and do {
      croak "no such reference count tag in refcount_decrement()"
        unless exists $kr_sessions{$session}->[SS_EXTRA_REFS]->{$tag};
    };

    my $refcount = --$kr_sessions{$session}->[SS_EXTRA_REFS]->{$tag};

    if (ASSERT_REFCOUNT) {
      croak( "--- ", sid($session), " refcount for tag '$tag' dropped below 0" )
        if $refcount < 0;
    }

    if (TRACE_REFCOUNT) {
      carp( "--- ", sid($session), " refcount for tag '$tag' decremented to ",
            $refcount
          );
    }

    unless ($refcount) {
      remove_extra_reference($session, $tag);

      if (TRACE_REFCOUNT) {
        carp( "--- ", sid($session), " refcount for session is at ",
              $kr_sessions{$session}->[SS_REFCOUNT]
            );
      }
    }

    $self->collect_garbage($session);

    return $refcount;
  }

  explain_return("session id $session_id does not exist");
  $! = ESRCH;
  return;
}

#==============================================================================
# HANDLERS
#==============================================================================

# Add or remove event handlers from sessions.
sub state {
  my ($self, $event, $state_code, $state_alias) = @_;
  $state_alias = $event unless defined $state_alias;

  ASSERT_USAGE and do {
    croak "undefined event name in state()" unless defined $event;
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

  explain_return("session ($kr_active_session) does not exist");
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

ASSERT_RETURNS causes POE::Kernel's methods to croak instead of
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
