# $Id$

package POE::Kernel;

use strict;
use POSIX qw(errno_h fcntl_h sys_wait_h uname signal_h);
use Carp;
use vars qw( $poe_kernel $poe_tk_main_window );

use Exporter;
@POE::Kernel::ISA = qw(Exporter);
@POE::Kernel::EXPORT = qw( $poe_kernel $poe_tk_main_window );

#------------------------------------------------------------------------------
# Macro definitions.

use POE::Preprocessor;

macro sig_remove (<session>,<signal>) {
  delete $self->[KR_SESSIONS]->{<session>}->[SS_SIGNALS]->{<signal>};
  delete $self->[KR_SIGNALS]->{<signal>}->{<session>};
}

macro sid (<session>) {
  "session " . <session>->ID
}

macro ssid {
  "session " . $session->ID
}

macro ses_leak_hash (<field>) {
  if (my $leaked = keys(%{$sessions->{$session}->[<field>]})) {
    warn {% ssid %}, " leaked $leaked <field>\a\n";
    $errors++;
  }
}

macro kernel_leak_hash (<field>) {
  if (my $leaked = keys %{$self->[<field>]}) {
    warn "*** KERNEL LEAK: <field> = $leaked\a\n";
  }
}

macro kernel_leak_vec (<field>) {
  { my $bits = unpack('b*', $self->[KR_VECTORS]->[<field>]);
    if (index($bits, '1') >= 0) {
      warn "*** KERNEL LEAK: KR_VECTORS/<field> = $bits\a\n";
    }
  }
}

macro kernel_leak_array (<field>) {
  if (my $leaked = @{$self->[<field>]}) {
    warn "*** KERNEL LEAK: <field> = $leaked\a\n";
  }
}

macro assert_session_refcount (<session>,<count>) {
  ASSERT_REFCOUNT and do {
    die {% sid <session> %}, " reference count <count> went below zero\n"
      if $self->[KR_SESSIONS]->{<session>}->[<count>] < 0;
  };
}


macro ses_refcount_dec (<session>) {
  $self->[KR_SESSIONS]->{<session>}->[SS_REFCOUNT]--;
  {% assert_session_refcount <session>, SS_REFCOUNT %}
}

macro ses_refcount_dec2 (<session>,<count>) {
  $self->[KR_SESSIONS]->{<session>}->[<count>]--;
  {% assert_session_refcount <session>, <count> %}
  {% ses_refcount_dec <session> %}
}

macro ses_refcount_inc (<session>) {
  $self->[KR_SESSIONS]->{<session>}->[SS_REFCOUNT]++;
}

macro ses_refcount_inc2 (<session>,<count>) {
  $self->[KR_SESSIONS]->{<session>}->[<count>]++;
  {% ses_refcount_inc <session> %}
}

macro remove_extra_reference (<session>,<tag>) {
  delete $self->[KR_SESSIONS]->{<session>}->[SS_EXTRA_REFS]->{<tag>};
  {% ses_refcount_dec <session> %}
}

# There is an string equality test in alias_resolve that should not be
# made into a numeric equality test.  <name> is often a string.

macro alias_resolve (<name>) {
  # Resolve against sessions.
  ( (exists $self->[KR_SESSIONS]->{<name>})
    ? $self->[KR_SESSIONS]->{<name>}->[SS_SESSION]
    # Resolve against IDs.
    : ( (exists $self->[KR_SESSION_IDS]->{<name>})
        ? $self->[KR_SESSION_IDS]->{<name>}
        # Resolve against aliases.
        : ( (exists $self->[KR_ALIASES]->{<name>})
            ? $self->[KR_ALIASES]->{<name>}
            # Resolve against self.
            : ( (<name> eq $self)
                ? $self
                # Game over!
                : undef
              )
          )
      )
  )
}

macro collect_garbage (<session>) {
  if ( (<session> != $self)
       and (exists $self->[KR_SESSIONS]->{<session>})
       and (!$self->[KR_SESSIONS]->{<session>}->[SS_REFCOUNT])
     ) {
    TRACE_GARBAGE and $self->trace_gc_refcount(<session>);
    ASSERT_GARBAGE and $self->assert_gc_refcount(<session>);
    $self->session_free(<session>);
  }
}

macro validate_handle (<handle>,<vector>) {
  # Don't bother if the kernel isn't tracking the handle.
  return 0 unless exists $self->[KR_HANDLES]->{<handle>};

  # Don't bother if the kernel isn't tracking the handle's write status.
  return 0 unless $self->[KR_HANDLES]->{<handle>}->[HND_VECCOUNT]->[<vector>];
}

macro remove_alias (<session>,<alias>) {
  delete $self->[KR_ALIASES]->{<alias>};
  delete $self->[KR_SESSIONS]->{<session>}->[SS_ALIASES]->{<alias>};
  {% ses_refcount_dec <session> %}
}

macro state_to_enqueue {
  [ @_[1..8], ++$queue_seqnum ]
}

macro define_trace (<const>) {
  defined &TRACE_<const> or eval 'sub TRACE_<const> () { TRACE_DEFAULT }';
}

macro define_assert (<const>) {
  defined &ASSERT_<const> or eval 'sub ASSERT_<const> () { ASSERT_DEFAULT }';
}

macro test_resolve (<name>,<resolved>) {
  unless (defined <resolved>) {
    ASSERT_SESSIONS and do {
      confess "Cannot resolve <name> into a session reference\n";
    };
    $! = ESRCH;
    return undef;
  }
}

macro clip_time_to_now (<time>) {
  if (<time> < (my $now = time())) {
    <time> = $now;
  }
}

# MACROS END <-- search tag for editing

#------------------------------------------------------------------------------

# Perform some optional setup.
BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';

  # Include Time::HiRes, which is pretty darned cool, if it's
  # available.  Life goes on without it.
  eval {
    require Time::HiRes;
    import Time::HiRes qw(time);
  };

  # Set a constant to indicate the presence of Time::HiRes.  This
  # enables some runtime optimization.
  if ($@) {
    eval 'sub POE_HAS_TIME_HIRES () { 0 }';
  }
  else {
    eval 'sub POE_HAS_TIME_HIRES () { 1 }';
  }

  # Provide a dummy EINPROGRESS for systems that don't have one.  Give
  # it an improbable errno value.
  if ($^O eq 'MSWin32') {
    eval '*EINPROGRESS = sub { 3.141 };'
  }
}

#------------------------------------------------------------------------------
# globals

$poe_kernel = undef;                    # only one active kernel; sorry

#------------------------------------------------------------------------------

# Debugging flags for subsystems.  They're done as double evals here
# so that someone may define them before using POE, and the
# pre-defined value will take precedence over the defaults here.
BEGIN {

  # TRACE_DEFAULT changes the default value for other TRACE_*
  # constants.  Since the define_trace macro uses TRACE_DEFAULT
  # internally, it can't be used to define TRACE_DEFAULT itself.

  defined &TRACE_DEFAULT or eval 'sub TRACE_DEFAULT () { 0 }';

  {% define_trace QUEUE    %}
  {% define_trace PROFILE  %}
  {% define_trace SELECT   %}
  {% define_trace EVENTS   %}
  {% define_trace GARBAGE  %}
  {% define_trace REFCOUNT %}

  # See the notes for TRACE_DEFAULT, except read ASSERT and assert
  # where you see TRACE and trace.

  defined &ASSERT_DEFAULT or eval 'sub ASSERT_DEFAULT () { 0 }';

  {% define_assert SELECT      %}
  {% define_assert GARBAGE     %}
  {% define_assert RELATIONS   %}
  {% define_assert SESSIONS    %}
  {% define_assert REFCOUNT    %}
}

# Determine whether Tk is loaded.  If it is, set a constant that
# enables Tk behaviors throughout POE::Kernel.  If Tk isn't present,
# then the support code won't run, but it still needs to compile.  In
# this case, we define a series of dummy constant functions that
# replace the missing Tk calls.

BEGIN {
  if (exists $INC{'Tk.pm'}) {
    warn "POE: Tk version $Tk::VERSION is in use! Let's rock!\n";
    eval <<'    EOE';
      sub POE_HAS_TK () { 1 }
    EOE
  }
  else {
    eval <<'    EOE';
      sub POE_HAS_TK          () { 0 }
      sub Tk::MainLoop        () { 0 }
      sub Tk::MainWindow::new () { undef }
    EOE
  }
}

#------------------------------------------------------------------------------

# Handles and vectors sub-fields.
enum VEC_RD VEC_WR VEC_EX

# Session structure
enum   SS_SESSION SS_REFCOUNT SS_EVCOUNT SS_PARENT SS_CHILDREN SS_HANDLES
enum + SS_SIGNALS SS_ALIASES  SS_PROCESSES SS_ID SS_EXTRA_REFS SS_ALCOUNT

# session handle structure
enum   SH_HANDLE SH_REFCOUNT SH_VECCOUNT

# The Kernel object.  KR_SIZE goes last (it's the index count).
enum   KR_SESSIONS KR_VECTORS KR_HANDLES KR_STATES KR_SIGNALS KR_ALIASES
enum + KR_ACTIVE_SESSION KR_PROCESSES KR_ALARMS KR_ID KR_SESSION_IDS
enum + KR_ID_INDEX KR_TK_TIMED KR_TK_IDLE KR_SIZE

# Handle structure.
enum HND_HANDLE HND_REFCOUNT HND_VECCOUNT HND_SESSIONS HND_FILENO

# Handle session structure.
enum HSS_HANDLE HSS_SESSION HSS_STATE

# State transition events.
enum ST_SESSION ST_SOURCE ST_NAME ST_TYPE ST_ARGS

# These go towards the end, in this order, because they're optional
# parameters in some cases.
enum + ST_TIME ST_OWNER_FILE ST_OWNER_LINE ST_SEQ

# These are names of internal events.

const EN_START  '_start'
const EN_STOP   '_stop'
const EN_SIGNAL '_signal'
const EN_GC     '_garbage_collect'
const EN_PARENT '_parent'
const EN_CHILD  '_child'
const EN_SCPOLL '_sigchld_poll'

# These are event classes (types).  They often shadow actual event
# names, but they can encompass a large group of events.  For example,
# ET_ALARM describes anything posted by an alarm call.  Types are
# preferred over names because bitmask tests tend to be faster than
# string equality checks.

const ET_USER   0x0000
const ET_START  0x0001
const ET_STOP   0x0002
const ET_SIGNAL 0x0004
const ET_GC     0x0008
const ET_PARENT 0x0010
const ET_CHILD  0x0020
const ET_SCPOLL 0x0040
const ET_ALARM  0x0080
const ET_SELECT 0x0100

# The amount of time to spend dispatching FIFO events.  Increasing
# this value will improve POE's FIFO dispatch performance by
# increasing the time between select and alarm checks.

const FIFO_DISPATCH_TIME 0.01

#------------------------------------------------------------------------------
# Here is a roadmap of POE's internal data structures.  It's complex
# enough that even the author needs a scorecard.
#------------------------------------------------------------------------------
#
# states:
# [ [ $session, $source_session, $state, $type, \@etc, $time,
#     $poster_file, $poster_line, $debug_sequence
#   ],
#   ...
# ]
#
# alarms:
# [ [ $session, $source_session, $state, $type, \@etc, $time,
#     $poster_file, $poster_line, $debug_sequence
#   ],
#   ...
# ]
#
# processes: { $pid => $parent_session, ... }
#
# kernel ID: { $kernel_id }
#
# session IDs: { $id => $session, ... }
#
# handles:
# { $handle =>
#   [ $handle,
#     $refcount,
#     [ $ref_r, $ref_w, $ref_x ],
#     [ { $session => [ $handle, $session, $state ], .. },
#       { $session => [ $handle, $session, $state ], .. },
#       { $session => [ $handle, $session, $state ], .. }
#     ]
#   ]
# };
#
# vectors: [ $read_vector, $write_vector, $expedite_vector ];
#
# signals: { $signal => { $session => $state, ... } };
#
# sessions:
# { $session =>
#   [ $session,     # blessed version of the key
#     $refcount,    # number of things keeping this alive
#     $evcnt,       # event count
#     $parent,      # parent session
#     { $child => $child, ... },
#     { $handle =>
#       [ $hdl,
#         $rcnt,
#         [ $r,$w,$e ]
#       ],
#       ...
#     },
#     { $signal => $state, ... },
#     { $name => 1, ... },
#     { $pid => 1, ... },          # child processes
#     $session_id,                 # session ID
#     { $tag => $count, ... },     # extra reference counts
#     $alarm_count,                # alarm count
#   ]
# };
#
# names: { $name => $session };
#
#------------------------------------------------------------------------------

#==============================================================================
# SIGNALS
#==============================================================================

# This is a list of signals that will terminate sessions that don't
# handle them.

my %_terminal_signals =
  ( QUIT => 1, INT => 1, KILL => 1, TERM => 1, HUP => 1, IDLE => 1 );

# This is the generic signal handler.  It posts the signal notice to
# the POE kernel, which propagates it to every session.

sub _signal_handler_generic {
  if (defined $_[0]) {
    $poe_kernel->_enqueue_state( $poe_kernel, $poe_kernel,
                                 EN_SIGNAL, ET_SIGNAL,
                                 [ $_[0] ],
                                 time(), __FILE__, __LINE__
                               );
    $SIG{$_[0]} = \&_signal_handler_generic;
  }
  else {
    warn "POE::Kernel::_signal_handler_generic detected an undefined signal";
  }
}

# SIGPIPE is handled a little differently.  It tends to be
# synchronous, so it's posted at the current active session.  We can
# do this better by generating a pseudo SIGPIPE whenever a driver
# returns EPIPE, but that requires people to use Wheel::ReadWrite on
# similar dilligence.

sub _signal_handler_pipe {
  if (defined $_[0]) {
    $poe_kernel->_enqueue_state( $poe_kernel->[KR_ACTIVE_SESSION], $poe_kernel,
                                 EN_SIGNAL, ET_SIGNAL,
                                 [ $_[0] ],
                                 time(), __FILE__, __LINE__
                               );
    $SIG{$_[0]} = \&_signal_handler_pipe;
  }
  else {
    warn "POE::Kernel::_signal_handler_pipe detected an undefined signal";
  }
}

# SIGCH?LD are normalized to SIGCHLD and include the child process'
# PID and return code.

sub _signal_handler_child {
  if (defined $_[0]) {

    # Reap until there are no more children.

    while ( ( my $pid = waitpid(-1, WNOHANG) ) >= 0 ) {

      # Determine if the child process is really exiting and not just
      # stopping for some other reason.  This is per Perl Cookbook
      # recipe 16.19.
      if (WIFEXITED($?)) {
        $poe_kernel->_enqueue_state( $poe_kernel, $poe_kernel,
                                     EN_SIGNAL, ET_SIGNAL,
                                     [ 'CHLD', $pid, $? ],
                                     time(), __FILE__, __LINE__
                                   );
      }
    }

    $SIG{$_[0]} = \&_signal_handler_child;
  }
  else {
    warn "POE::Kernel::_signal_handler_child detected an undefined signal";
  }
}

#------------------------------------------------------------------------------
# Register or remove signals.

# Public interface for adding or removing signal handlers.
sub sig {
  my ($self, $signal, $state) = @_;
  if (defined $state) {
    my $session = $self->[KR_ACTIVE_SESSION];
    $self->[KR_SESSIONS]->{$session}->[SS_SIGNALS]->{$signal} = $state;
    $self->[KR_SIGNALS]->{$signal}->{$session} = $state;
  }
  else {
    {% sig_remove $self->[KR_ACTIVE_SESSION], $signal %}
  }
}

# Public interface for posting signal events.  5.6.0 places a signal
# symbol in our table; the BEGIN block deletes it to prevent
# "Subroutine signal redefined" warnings.

BEGIN { delete $POE::Kernel::{signal}; }
sub POE::Kernel::signal {
  my ($self, $destination, $signal) = @_;

  my $session = {% alias_resolve $destination %};
  {% test_resolve $destination, $session %}

  $self->_enqueue_state( $session, $self->[KR_ACTIVE_SESSION],
                         EN_SIGNAL, ET_SIGNAL,
                         [ $signal ],
                         time(), (caller)[1,2]
                       );
}

#==============================================================================
# KERNEL
#==============================================================================

sub new {
  my $type = shift;

  # Prevent multiple instances, no matter how many times it's called.
  # This is a backward-compatibility enhancement for programs that
  # have used versions prior to 0.06.
  unless (defined $poe_kernel) {

    $poe_tk_main_window = Tk::MainWindow->new();

    # If we have a Tk main window, then register an onDestroy handler
    # for it.  This handler broadcasts a terminal TKDESTROY signal to
    # every session.

    if (defined $poe_tk_main_window) {
      $poe_tk_main_window->OnDestroy
        ( sub {
            $poe_kernel->_dispatch_state
              ( $poe_kernel, $poe_kernel,
                EN_SIGNAL, ET_SIGNAL, [ 'TKDESTROY' ],
                time(), __FILE__, __LINE__, undef
              );
          }
        );
    }

    my $self = $poe_kernel = bless
      [ { },                            # KR_SESSIONS
        [ '', '', '' ],                 # KR_VECTORS
        { },                            # KR_HANDLES
        [ ],                            # KR_STATES
        { },                            # KR_SIGNALS
        { },                            # KR_ALIASES
        undef,                          # KR_ACTIVE_SESSION
        { },                            # KR_PROCESSES
        [ ],                            # KR_ALARMS
        undef,                          # KR_ID
        { },                            # KR_SESSION_IDS
        1,                              # KR_ID_INDEX
        undef,                          # KR_TK_TIMED
        undef,                          # KR_TK_IDLE
      ], $type;


    # Kernel ID, based on Philip Gwyn's code.  I hope he still can
    # recognize it.  KR_SESSION_IDS is a hash because it will almost
    # always be sparse.
    $self->[KR_ID] = ( (uname)[1] . '-' .
                       unpack 'H*', pack 'N*', time, $$
                     );

    # Initialize the vectors as vectors.
    vec($self->[KR_VECTORS]->[VEC_RD], 0, 1) = 0;
    vec($self->[KR_VECTORS]->[VEC_WR], 0, 1) = 0;
    vec($self->[KR_VECTORS]->[VEC_EX], 0, 1) = 0;

    # Register all known signal handlers, except the troublesome ones.
    foreach my $signal (keys(%SIG)) {

      # Some signals aren't real, and the act of setting handlers for
      # them can have strange, even fatal side effects.  Recognize and
      # ignore them.
      next if ($signal =~ /^( NUM\d+
                              |__[A-Z0-9]+__
                              |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE
                              |RTMIN|RTMAX|SETS
                              |SEGV
                              |
                            )$/x
              );

      # Artur has been experiencing problems where POE programs crash
      # after resizing xterm windows.  It was discovered that the
      # xterm resizing was sending several WINCH signals, which
      # eventually causes Perl to become unstable.  Ignoring SIGWINCH
      # seems to prevent the problem, but it's only a temporary
      # solution.  At some point, POE will include a set of Curses
      # widgets, and SIGWINCH will be needed...
      if ($signal eq 'WINCH') {
        $SIG{$signal} = 'IGNORE';
        next;
      }

      # Windows doesn't have a SIGBUS, but the debugger causes SIGBUS
      # to be entered into %SIG.  Registering a handler for it becomes
      # a fatal error.  Don't do that!
      if ($signal eq 'BUS' and $^O eq 'MSWin32') {
        next;
      }

      # Register signal handlers by type.
      if ($signal =~ /^CH?LD$/) {

        # Leave SIGCHLD alone if running under apache.
        unless (exists $INC{'Apache.pm'}) {
          $SIG{$signal} = \&_signal_handler_child;
        }
      }
      elsif ($signal eq 'PIPE') {
        $SIG{$signal} = \&_signal_handler_pipe;
      }
      else {
        $SIG{$signal} = \&_signal_handler_generic;
      }

      $self->[KR_SIGNALS]->{$signal} = { };
    }

    # The kernel is a session, sort of.
    $self->[KR_ACTIVE_SESSION] = $self;
    $self->[KR_SESSIONS]->{$self} =
      [ $self,                          # SS_SESSION
        0,                              # SS_REFCOUNT
        0,                              # SS_EVCOUNT
        undef,                          # SS_PARENT
        { },                            # SS_CHILDREN
        { },                            # SS_HANDLES
        { },                            # SS_SIGNALS
        { },                            # SS_ALIASES
        { },                            # SS_PROCESSES
        $self->[KR_ID],                 # SS_ID
        { },                            # SS_EXTRA_REFS
        0,                              # SS_ALCOUNT
      ];
  }

  # Return the global instance.
  $poe_kernel;
}

#------------------------------------------------------------------------------
# Send a state to a session right now.  Used by _disp_select to
# expedite select() states, and used by run() to deliver posted states
# from the queue.

# This is for collecting state frequencies if TRACE_PROFILE is enabled.
my %profile;

# Dispatch a stat transition event to its session.  A lot of work goes
# on here.

sub _dispatch_state {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line, $seq
     ) = @_;

  # A copy of the state name, in case we have to change it.
  my $local_state = $state;

  # We do a lot with the sessions structure.  Cache it in a lexical to
  # save on dereferences.
  my $sessions = $self->[KR_SESSIONS];

  TRACE_PROFILE and $profile{$state}++;

  # Pre-dispatch processing.

  if ($type) {

    # The _start state is dispatched immediately as part of allocating
    # a session.  Set up the kernel's tables for this session.

    if ($type & ET_START) {
      my $new_session = $sessions->{$session} =
        [ $session,                     # SS_SESSION
          0,                            # SS_REFCOUNT
          0,                            # SS_EVCOUNT
          $source_session,              # SS_PARENT
          { },                          # SS_CHILDREN
          { },                          # SS_HANDLES
          { },                          # SS_SIGNALS
          { },                          # SS_ALIASES
          { },                          # SS_PROCESSES
          $self->[KR_ID_INDEX]++,       # SS_ID
          { },                          # SS_EXTRA_REFS
          0,                            # SS_ALCOUNT
        ];

      # For the ID to session reference lookup.
      $self->[KR_SESSION_IDS]->{$new_session->[SS_ID]} = $session;

      # Ensure sanity.
      ASSERT_RELATIONS and do {
        die {% ssid %}, " is its own parent\a"
          if ($session == $source_session);

        die( {% ssid %},
             " already is a child of ", {% sid $source_session %}, "\a"
           )
          if (exists $sessions->{$source_session}->[SS_CHILDREN]->{$session});
      };

      # Add the new session to its parent's children.
      $sessions->{$source_session}->[SS_CHILDREN]->{$session} = $session;
      {% ses_refcount_inc $source_session %}
    }

    # Some sessions don't do anything in _start and expect their
    # creators to provide a start-up event.  This means we can't
    # &_collect_garbage at _start time.  Instead, we post a
    # garbage-collect event at start time, and &_collect_garbage at
    # delivery time.  This gives the session's creator time to do
    # things with it before we reap it.

    elsif ($type & ET_GC) {
      {% collect_garbage $session %}
      return 0;
    }

    # A session's about to stop.  Notify its parents and children of
    # the impending change in their relationships.  Incidental _stop
    # events are handled before the dispatch.

    elsif ($type & ET_STOP) {

      # Tell child sessions that they have a new parent (the departing
      # session's parent).  Tell the departing session's parent that
      # it has new child sessions.

      my $parent   = $sessions->{$session}->[SS_PARENT];
      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach my $child (@children) {
        $self->_dispatch_state( $parent, $self,
                                EN_CHILD, ET_CHILD,
                                [ 'gain', $child ],
                                time(), $file, $line, undef
                              );
        $self->_dispatch_state( $child, $self,
                                EN_PARENT, ET_PARENT,
                                [ $sessions->{$child}->[SS_PARENT], $parent, ],
                                time(), $file, $line, undef
                              );
      }

      # Tell the departing session's parent that the departing session
      # is departing.

      if (defined $parent) {
        $self->_dispatch_state( $parent, $self,
                                EN_CHILD, ET_CHILD,
                                [ 'lose', $session ],
                                time(), $file, $line, undef
                              );
      }
    }

    # Preprocess signals.  This is where _signal is translated into
    # its registered handler's state name, if there is one.

    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];

      # Propagate the signal to this session's children.  This happens
      # first, making the signal's traversal through the parent/child
      # tree depth first.  It ensures that signals posted to the
      # Kernel are delivered to the Kernel last.

      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach (@children) {
        $self->_dispatch_state( $_, $self,
                                $state, ET_SIGNAL,
                                $etc,
                                time(), $file, $line, undef
                              );
      }

      # Translate the '_signal' state to its handler's name.

      if (exists $self->[KR_SIGNALS]->{$signal}->{$session}) {
        $local_state = $self->[KR_SIGNALS]->{$signal}->{$session};
      }
    }
  }

  # The destination session doesn't exist.  This is an indication of
  # sloppy programming, either on POE's author's part or its user's
  # part.

  unless (exists $self->[KR_SESSIONS]->{$session}) {
    TRACE_EVENTS and do {
      warn ">>> discarding $state to nonexistent ", {% ssid %}, "\n";
    };
    return;
  }

  TRACE_EVENTS and do {
    warn ">>> dispatching $state to ", {% ssid %}, "\n";
  };

  # Prepare to call the appropriate state.  Push the current active
  # session on Perl's call stack.
  my $hold_active_session = $self->[KR_ACTIVE_SESSION];
  $self->[KR_ACTIVE_SESSION] = $session;

  # Dispatch the event, at long last.
  my $return =
    $session->_invoke_state($source_session, $local_state, $etc, $file, $line);

  # Stringify the state's return value if it belongs in the POE
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
  $self->[KR_ACTIVE_SESSION] = $hold_active_session;

  TRACE_EVENTS and do {
    warn "<<< ", {% ssid %}, " -> $state returns ($return)\n";
  };

  # Post-dispatch processing.

  if ($type) {

    # A new session has started.  Tell its parent.  Incidental _start
    # events are fired after the dispatch.

    if ($type & ET_START) {
      $self->_dispatch_state( $sessions->{$session}->[SS_PARENT], $self,
                              EN_CHILD, ET_CHILD,
                              [ 'create', $session, $return ],
                              time(), $file, $line, undef
                            );
    }

    # This session has stopped.  Clean up after it.

    elsif ($type & ET_STOP) {

      # Remove the departing session from its parent.

      my $parent = $sessions->{$session}->[SS_PARENT];
      if (defined $parent) {

        ASSERT_RELATIONS and do {
          die {% ssid %}, " is its own parent\a" if ($session == $parent);
          die {% ssid %}, " is not a child of ", {% sid $parent %}, "\a"
            unless ( ($session == $parent) or
                     exists($sessions->{$parent}->[SS_CHILDREN]->{$session})
                   );
        };

        delete $sessions->{$parent}->[SS_CHILDREN]->{$session};
        {% ses_refcount_dec $parent %}
      }

      # Give the departing session's children to its parent.

      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach (@children) {
        ASSERT_RELATIONS and do {
          die {% sid $_ %}, " is already a child of ", {% sid $parent %}, "\a"
            if (exists $sessions->{$parent}->[SS_CHILDREN]->{$_});
        };

        $sessions->{$_}->[SS_PARENT] = $parent;
        if (defined $parent) {
          $sessions->{$parent}->[SS_CHILDREN]->{$_} = $_;
          {% ses_refcount_inc $parent %}
        }

        delete $sessions->{$session}->[SS_CHILDREN]->{$_};
        {% ses_refcount_dec $session %}
      }

      # Free any signals that the departing session allocated.

      my @signals = keys %{$sessions->{$session}->[SS_SIGNALS]};
      foreach (@signals) {
        {% sig_remove $session, $_ %}
      }

      # Free any events that the departing session has in the queue.

      my $states = $self->[KR_STATES];
      my $index = @$states;
      while ($index-- && $sessions->{$session}->[SS_EVCOUNT]) {
        if ($states->[$index]->[ST_SESSION] == $session) {

          {% ses_refcount_dec2 $session, SS_EVCOUNT %}

          splice(@$states, $index, 1);
        }
      }

      # Free any alarms that the departing session has in its queue.

      my $alarms = $self->[KR_ALARMS];
      $index = @$alarms;
      while ($index-- && $sessions->{$session}->[SS_ALCOUNT]) {
        if ($alarms->[$index]->[ST_SESSION] == $session) {

          {% ses_refcount_dec2 $session, SS_ALCOUNT %}

          splice(@$alarms, $index, 1);
        }
      }

      # Close any selects that the session still has open.  -><- This
      # is heavy handed; it does work it doesn't need to do.  There
      # must be a better way.

      my @handles = values %{$sessions->{$session}->[SS_HANDLES]};
      foreach (@handles) {
        $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_RD);
        $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_WR);
        $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_EX);
      }

      # Close any lingering extra references.
      my @extra_refs = keys %{$sessions->{$session}->[SS_EXTRA_REFS]};
      foreach (@extra_refs) {
        {% remove_extra_reference $session, $_ %}
      }

      # Release any aliases still registered to the session.

      my @aliases = keys %{$sessions->{$session}->[SS_ALIASES]};
      foreach (@aliases) {
        {% remove_alias $session, $_ %}
      }

      # Clear the session ID.  The undef part is completely
      # gratuitous; I don't know why I put it there.

      delete $self->[KR_SESSION_IDS]->{$sessions->{$session}->[SS_ID]};
      $session->[SS_ID] = undef;

      # And finally, check all the structures for leakage.  POE's
      # pretty complex internally, so this is a happy fun check.

      ASSERT_GARBAGE and do {
        my $errors = 0;

        if (my $leaked = $sessions->{$session}->[SS_REFCOUNT]) {
          warn {% ssid %}, " has a refcount leak: $leaked\a\n";
          $errors++;
        }

        foreach my $l (sort keys %{$sessions->{$session}->[SS_EXTRA_REFS]}) {
          my $count = $sessions->{$session}->[SS_EXTRA_REFS]->{$l};
          if ($count) {
            warn( {% ssid %}, " leaked an extra reference: ",
                  "(tag=$l) (count=$count)\a\n"
                );
            $errors++;
          }
        }

        {% ses_leak_hash SS_CHILDREN %}
        {% ses_leak_hash SS_HANDLES  %}
        {% ses_leak_hash SS_SIGNALS  %}
        {% ses_leak_hash SS_ALIASES  %}

        die "\a" if ($errors);
      };

      # Remove the session's structure from the kernel's structure.
      delete $sessions->{$session};

      # Check the parent to see if it's time to garbage collect.  This
      # is here because POE::Kernel is sort of a session, and it has
      # no parent.
      if (defined $parent) {
        {% collect_garbage $parent %}
      }
    }

    # Check for death by terminal signal.

    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];

      # Determine if the signal is fatal and some junk.
      if ( ($signal eq 'ZOMBIE') or
           ($signal eq 'TKDESTROY') or
           (!$return && exists($_terminal_signals{$signal}))
         ) {
        $self->session_free($session);
      }

      # Otherwise just garbage collect.  -><- Is this necessary?
      else {
        {% collect_garbage $session %}
      }
    }
  }

  # Return what the state did.  This is used for call().
  $return;
}

#------------------------------------------------------------------------------
# POE's main loop!  Now with Tk support!

sub run {
  my $self = shift;

  # Use Tk's main loop, if Tk is loaded.

  if (POE_HAS_TK) {
    eval 'Tk::MainLoop';
  }

  # Otherwise use POE's main loop.

  else {

    # Cache some deferences.  Adds about 15 events/second to a trivial
    # benchmark.
    my $kr_states   = $self->[KR_STATES];
    my $kr_handles  = $self->[KR_HANDLES];
    my $kr_sessions = $self->[KR_SESSIONS];
    my $kr_vectors  = $self->[KR_VECTORS];
    my $kr_alarms   = $self->[KR_ALARMS];

    # Continue running while there are sessions that need to be
    # serviced.

    while (keys %$kr_sessions) {

      # If the FIFO is empty, and there are no pending alarms, and
      # there are no event generators (such as filehandles), then the
      # main loop may be ready to end.  Broadcast a SIGIDLE to begin a
      # graceful shutdown.  Sessions may react to this in ways that
      # prevent the shutdown from completing.

      # -><- It may be more efficient to manage a kernel reference
      # count when states, alarms and handles are added or removed.
      # This then would become a single scalar reference check.

      unless (@$kr_states || @$kr_alarms || keys(%$kr_handles)) {
        $self->_enqueue_state( $self, $self,
                               EN_SIGNAL, ET_SIGNAL,
                               [ 'IDLE' ],
                               time(), __FILE__, __LINE__
                             );
      }

      # Set the select timeout based on current queue conditions.  If
      # there are FIFO events, then the timeout is zero to poll select
      # and move on.  Otherwise set the select timeout until the next
      # pending alarm, if any are in the alarm queue.  If no FIFO
      # events or alarms are pending, then time out after some
      # constant number of seconds.

      my $now = time();
      my $timeout;

      if (@$kr_states) {
        $timeout = 0;
      }
      elsif (@$kr_alarms) {
        $timeout = $kr_alarms->[0]->[ST_TIME] - $now;
        $timeout = 0 if $timeout < 0;
      }
      else {
        $timeout = 3600;
      }

      TRACE_QUEUE and do {
        warn( '*** Kernel::run() iterating.  ' .
              sprintf("now(%.2f) timeout(%.2f) then(%.2f)\n",
                      $now-$^T, $timeout, ($now-$^T)+$timeout
                     )
            );
        warn( '*** Alarm times: ' .
              join( ', ',
                    map { sprintf('%d=%.2f',
                                  $_->[ST_SEQ], $_->[ST_TIME] - $now
                                 )
                        } @$kr_alarms
                  ) .
              "\n"
            );
      };

      TRACE_SELECT and do {
        warn ",----- SELECT BITS IN -----\n";
        warn "| READ    : ", unpack('b*', $kr_vectors->[VEC_WR]), "\n";
        warn "| WRITE   : ", unpack('b*', $kr_vectors->[VEC_WR]), "\n";
        warn "| EXPEDITE: ", unpack('b*', $kr_vectors->[VEC_EX]), "\n";
        warn "`--------------------------\n";
      };

      # Avoid looking at filehandles if we don't need to.

      if ($timeout || keys(%$kr_handles)) {

        # Check filehandles, or wait for a period of time to elapse.

        my $hits = select( my $rout = $kr_vectors->[VEC_RD],
                           my $wout = $kr_vectors->[VEC_WR],
                           my $eout = $kr_vectors->[VEC_EX],
                           ($timeout < 0) ? 0 : $timeout
                         );

        ASSERT_SELECT and do {
          if ($hits < 0) {
            die "select error = $!\n"
              unless ( ($! == EINPROGRESS) or ($! == EINTR) );
          }
        };

        TRACE_SELECT and do {
          if ($hits > 0) {
            warn "select hits = $hits\n";
          }
          elsif ($hits == 0) {
            warn "select timed out...\n";
          }
          warn ",----- SELECT BITS OUT -----\n";
          warn "| READ    : ", unpack('b*', $rout), "\n";
          warn "| WRITE   : ", unpack('b*', $wout), "\n";
          warn "| EXPEDITE: ", unpack('b*', $eout), "\n";
          warn "`---------------------------\n";
        };

        # If select has seen filehandle activity, then gather up the
        # active filehandles and synchronously dispatch events to the
        # appropriate states.

        if ($hits > 0) {

          # This is where they're gathered.  It's a variant on a neat
          # hack Silmaril came up with.

          # -><- This does extra work.  Some of $%kr_handles don't
          # have all their bits set (for example; VEX_EX is rarely
          # used).  It might be more efficient to split this into
          # three greps, for just the vectors that need to be checked.

          # -><- It has been noted that map is slower than foreach
          # when the size of a list is grown.  The list is exploded on
          # the stack and manipulated with stack ops, which are slower
          # than just pushing on a list.  Evil probably ensues here.

          my @selects =
            map { ( ( vec($rout, $_->[HND_FILENO], 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_RD]})
                      : ( )
                    ),
                    ( vec($wout, $_->[HND_FILENO], 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_WR]})
                      : ( )
                    ),
                    ( vec($eout, $_->[HND_FILENO], 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_EX]})
                      : ( )
                    )
                  )
                } values %$kr_handles;

          TRACE_SELECT and do {
            if (@selects) {
              warn "found pending selects: @selects\n";
            }
          };

          ASSERT_SELECT and do {
            unless (@selects) {
              die "found no selects, with $hits hits from select???\a\n";
            }
          };

          # Dispatch the gathered selects.  They're dispatched right
          # away because files will continue to unblock select until
          # they're taken care of.  The idea is for select handlers to
          # do whatever is needed to shut up select, and then they
          # post something indicating what input was got.  Nobody
          # seems to use them this way, though, not even the author.

          foreach my $select (@selects) {

            $self->_dispatch_state
              ( $select->[HSS_SESSION], $select->[HSS_SESSION],
                $select->[HSS_STATE], ET_SELECT,
                [ $select->[HSS_HANDLE] ],
                time(), __FILE__, __LINE__, undef
              );
            {% collect_garbage $select->[HSS_SESSION] %}
          }
        }
      }

      # Dispatch whatever alarms are due.

      $now = time();
      while ( @$kr_alarms and ($kr_alarms->[0]->[ST_TIME] <= $now) ) {

        TRACE_QUEUE and do {
          my $event = $kr_alarms->[0];
          warn( sprintf('now(%.2f) ', $now - $^T) .
                sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
                "seq($event->[ST_SEQ])  " .
                "name($event->[ST_NAME])\n"
              )
        };

        # Pull an alarm off the queue.
        my $event = shift @$kr_alarms;
        {% ses_refcount_dec2 $event->[ST_SESSION], SS_ALCOUNT %}

        # Dispatch it, and see if that was the last thing the session
        # needed to do.
        $self->_dispatch_state(@$event);
        {% collect_garbage $event->[ST_SESSION] %}
      }

      # Dispatch one or more FIFOs, if they are available.  There is a
      # lot of latency between executions of this code block, so we'll
      # dispatch more than one event if we can.

      my $stop_time = time() + FIFO_DISPATCH_TIME;
      while (@$kr_states) {

        TRACE_QUEUE and do {
          my $event = $kr_states->[0];
          warn( sprintf('now(%.2f) ', $now - $^T) .
                sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
                "seq($event->[ST_SEQ])  " .
                "name($event->[ST_NAME])\n"
              )
        };

        # Pull an event off the queue.
        my $event = shift @$kr_states;
        {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}

        # Dispatch it, and see if that was the last thing the session
        # needed to do.
        $self->_dispatch_state(@$event);
        {% collect_garbage $event->[ST_SESSION] %}

        # If Time::HiRes isn't available, then the fairest thing to do
        # is loop immediately.
        last unless POE_HAS_TIME_HIRES;

        # Otherwise, dispatch more FIFO events until $stop_time is
        # reached.
        last unless time() < $stop_time;
      }
    }
  }

  # The main loop is done, no matter which event library ran it.
  # Let's make sure POE isn't leaking things.

  ASSERT_GARBAGE and do {
    {% kernel_leak_vec VEC_RD %}
    {% kernel_leak_vec VEC_WR %}
    {% kernel_leak_vec VEC_EX %}

    {% kernel_leak_hash KR_PROCESSES   %}
    {% kernel_leak_hash KR_SESSION_IDS %}
    {% kernel_leak_hash KR_HANDLES     %}
    {% kernel_leak_hash KR_SESSIONS    %}
    {% kernel_leak_hash KR_ALIASES     %}

    {% kernel_leak_array KR_ALARMS %}
    {% kernel_leak_array KR_STATES %}
  };

  TRACE_PROFILE and do {
    my $title = ',----- State Profile ';
    $title .= '-' x (74 - length($title)) . ',';
    warn $title, "\n";
    foreach (sort keys %profile) {
      printf "| %60s %10d |\n", $_, $profile{$_};
    }
    warn '`', '-' x 73, "'\n";
  }
}

# Tk idle callback to dispatch FIFO states.  This steals a big chunk
# of code from POE::Kernel::run().  Make this function's guts a macro
# later, and use it in both places.

sub tk_fifo_callback {
  my $self = $poe_kernel;

  if ( @{ $self->[KR_STATES] } ) {

    # Pull an event off the queue.

    my $event = shift @{ $self->[KR_STATES] };
    {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}

    # Dispatch it, and see if that was the last thing the session
    # needed to do.

    $self->_dispatch_state(@$event);
    {% collect_garbage $event->[ST_SESSION] %}

  }

  # Perpetuate the dispatch loop as long as there are states enqueued.

  if (defined $self->[KR_TK_IDLE]) {
    $self->[KR_TK_IDLE]->cancel();
    $self->[KR_TK_IDLE] = undef;
  }

  # This nasty little hack is required because setting an afterIdle
  # from a running afterIdle effectively blocks OS/2 Presentation
  # Manager events.  This locks up its notion of a window manager.  I
  # couldn't get anyone to test it on other platforms... (Hey, this could
  # trash yoru desktop! Wanna try it?) :)

  if (@{$self->[KR_STATES]}) {
    $poe_tk_main_window->after
      ( 0,
        sub {
          $self->[KR_TK_IDLE] =
            $poe_tk_main_window->afterIdle( \&tk_fifo_callback )
          unless defined $self->[KR_TK_IDLE];
        }
      );
  }
}

# Tk timer callback to dispatch alarm states.  Same caveats about
# macro-izing this code.

sub tk_alarm_callback {
  my $self = $poe_kernel;

  # Dispatch whatever alarms are due.

  my $now = time();
  while ( @{ $self->[KR_ALARMS] } and
          ($self->[KR_ALARMS]->[0]->[ST_TIME] <= $now)
        ) {

    # Pull an alarm off the queue.

    my $event = shift @{ $self->[KR_ALARMS] };
    {% ses_refcount_dec2 $event->[ST_SESSION], SS_ALCOUNT %}

    # Dispatch it, and see if that was the last thing the session
    # needed to do.

    $self->_dispatch_state(@$event);
    {% collect_garbage $event->[ST_SESSION] %}

  }

  # Register the next timed callback if there are alarms left.

  if (@{$self->[KR_ALARMS]}) {

    if (defined $self->[KR_TK_TIMED]) {
      $self->[KR_TK_TIMED]->cancel();
      $self->[KR_TK_TIMED] = undef;
    }

    my $next_time = $self->[KR_ALARMS]->[0]->[ST_TIME] - time();
    $next_time = 0 if $next_time < 0;

    $self->[KR_TK_TIMED] =
      $poe_tk_main_window->after( $next_time * 1000,
                                  \&tk_alarm_callback
                                );
  }

}

# Tk filehandle callback to dispatch selects.

sub tk_select_callback {
  my $self = $poe_kernel;
  my ($handle, $vector) = @_;

warn "called back";

  my @selects =
    values %{ $self->[KR_HANDLES]->{$handle}->[HND_SESSIONS]->[$vector] };

  foreach my $select (@selects) {

warn "session($select->[HSS_SESSION]) state($select->[HSS_STATE]) handle($select->[HSS_HANDLE])";

    $self->_dispatch_state
      ( $select->[HSS_SESSION], $select->[HSS_SESSION],
        $select->[HSS_STATE], ET_SELECT,
        [ $select->[HSS_HANDLE] ],
        time(), __FILE__, __LINE__, undef
      );
    {% collect_garbage $select->[HSS_SESSION] %}
  }

}

#------------------------------------------------------------------------------

sub DESTROY {
  # Destroy all sessions.  This will cascade destruction to all
  # resources.  It's taken care of by Perl's own garbage collection.
  # For completeness, I suppose a copy of POE::Kernel->run's leak
  # detection could be included here.
}

#------------------------------------------------------------------------------
# _invoke_state is what _dispatch_state calls to dispatch a transition
# event.  This is the kernel's _invoke_state so it can receive events.
# These are mostly signals, which are propagated down in
# _dispatch_state.

sub _invoke_state {
  my ($self, $source_session, $state, $etc) = @_;

  # POE::Kernel::fork was used, and an event loop was set up to reap
  # children.  It's time to check for children waiting.

  if ($state eq EN_SCPOLL) {

    # Non-blocking wait for a child process.  If one was reaped,
    # dispatch a SIGCHLD to the session who called fork.

    while ( ( my $pid = waitpid(-1, WNOHANG) ) >= 0 ) {

      # Determine if the child process is really exiting and not just
      # stopping for some other reason.  This is perl Perl Cookbook
      # recipe 16.19.

      if (WIFEXITED($?)) {

        # Map the process ID to a session reference.  First look for a
        # session registered via $kernel->fork().  Next validate the
        # session or signal everyone.

        my $parent_session = delete $self->[KR_PROCESSES]->{$pid};
        $parent_session = $self
          unless ( (defined $parent_session) and
                   exists $self->[KR_SESSIONS]->{$parent_session}
                 );

        # Enqueue the signal.

        $self->_enqueue_state( $parent_session, $self,
                               EN_SIGNAL, ET_SIGNAL,
                               [ 'CHLD', $pid, $? ],
                               time(), __FILE__, __LINE__
                             );
      }
      else {
        last;
      }
    }

    # If there still are processes waiting, post another EN_SCPOLL for
    # later.

    if (keys %{$self->[KR_PROCESSES]}) {
      $self->_enqueue_state( $self, $self,
                             EN_SCPOLL, ET_SCPOLL,
                             [],
                             time() + 1, __FILE__, __LINE__
                           );
    }
  }

  # A signal was posted.  Because signals propagate depth-first, this
  # _invoke_state is called last in the dispatch.  If the signal was
  # SIGIDLE, then post a SIGZOMBIE if the main queue is still idle.

  elsif ($state eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (@{$self->[KR_STATES]} || keys(%{$self->[KR_HANDLES]})) {
        $self->_enqueue_state( $self, $self,
                               EN_SIGNAL, ET_SIGNAL,
                               [ 'ZOMBIE' ],
                               time(), __FILE__, __LINE__
                             );
      }
    }
  }

  return 1;
}

#==============================================================================
# SESSIONS
#==============================================================================

# Dispatch _start to a session, allocating it in the kernel's data
# structures as a side effect.

sub session_alloc {
  my ($self, $session, @args) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  ASSERT_RELATIONS and do {
    die {% ssid %}, " already exists\a"
      if (exists $self->[KR_SESSIONS]->{$session});
  };

  $self->_dispatch_state( $session, $kr_active_session,
                          EN_START, ET_START,
                          \@args,
                          time(), __FILE__, __LINE__, undef
                        );
  $self->_enqueue_state( $session, $kr_active_session,
                         EN_GC, ET_GC,
                         [],
                         time(), __FILE__, __LINE__
                       );
}

# Dispatch _stop to a session, removing it from the kernel's data
# structures as a side effect.

sub session_free {
  my ($self, $session) = @_;

  ASSERT_RELATIONS and do {
    die {% ssid %}, " doesn't exist\a"
      unless (exists $self->[KR_SESSIONS]->{$session});
  };

  $self->_dispatch_state( $session, $self->[KR_ACTIVE_SESSION],
                          EN_STOP, ET_STOP,
                          [],
                          time(), __FILE__, __LINE__, undef
                        );

  # Is this necessary?  Shouldn't the session already be stopped?
  {% collect_garbage $session %}
}

# Debugging subs for reference count checks.

sub trace_gc_refcount {
  my ($self, $session) = @_;
  my $ss = $self->[KR_SESSIONS]->{$session};
  warn "+----- GC test for ", {% ssid %}, " -----\n";
  warn "| ref. count    : $ss->[SS_REFCOUNT]\n";
  warn "| event count   : $ss->[SS_EVCOUNT]\n";
  warn "| alarm count   : $ss->[SS_ALCOUNT]\n";
  warn "| child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n";
  warn "| handles in use: ", scalar(keys(%{$ss->[SS_HANDLES]})), "\n";
  warn "| aliases in use: ", scalar(keys(%{$ss->[SS_ALIASES]})), "\n";
  warn "| extra refs    : ", scalar(keys(%{$ss->[SS_EXTRA_REFS]})), "\n";
  warn "+---------------------------------------------------\n";
  warn("| Session ", {% ssid %}, " is garbage; recycling it...\n")
    unless $ss->[SS_REFCOUNT];
  warn "+---------------------------------------------------\n";
}

sub assert_gc_refcount {
  my ($self, $session) = @_;
  my $ss = $self->[KR_SESSIONS]->{$session};

  # Calculate the total reference count based on the number of
  # discrete references kept.

  my $calc_ref =
    ( $ss->[SS_EVCOUNT] +
      $ss->[SS_ALCOUNT] +
      scalar(keys(%{$ss->[SS_CHILDREN]})) +
      scalar(keys(%{$ss->[SS_HANDLES]})) +
      scalar(keys(%{$ss->[SS_EXTRA_REFS]})) +
      scalar(keys(%{$ss->[SS_ALIASES]}))
    );

  # The calculated reference count really ought to match the one POE's
  # been keeping track of all along.

  die "session ", {% ssid %}, " has a reference count inconsistency\n"
    if $calc_ref != $ss->[SS_REFCOUNT];

  # Compare held handles against reference counts for them.

  foreach (values %{$ss->[SS_HANDLES]}) {
    $calc_ref = $_->[SH_VECCOUNT]->[VEC_RD] +
      $_->[SH_VECCOUNT]->[VEC_WR] + $_->[SH_VECCOUNT]->[VEC_EX];

    die "session ", {% ssid %}, " has a handle reference count inconsistency\n"
      if $calc_ref != $_->[SH_REFCOUNT];
  }
}

#==============================================================================
# EVENTS
#==============================================================================

my $queue_seqnum = 0;

sub _enqueue_state {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line
     ) = @_;

  TRACE_EVENTS and do {
    warn "}}} enqueuing state '$state' for ", {% ssid %}, "\n";
  };

  # These things are FIFO; just enqueue it.

  if (exists $self->[KR_SESSIONS]->{$session}) {

    push @{$self->[KR_STATES]}, {% state_to_enqueue %};
    {% ses_refcount_inc2 $session, SS_EVCOUNT %}

    # If using Tk and the FIFO queue now has only one event, then
    # register a Tk idle callback to begin the dispatch loop.

    if ( POE_HAS_TK ) {
      $self->[KR_TK_IDLE] =
        $poe_tk_main_window->afterIdle( \&tk_fifo_callback );
    }

  }
  else {
    warn ">>>>> ", join('; ', keys(%{$self->[KR_SESSIONS]})), " <<<<<\n";
    croak "can't enqueue state($state) for nonexistent session($session)\a\n";
  }
}

sub _enqueue_alarm {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line
     ) = @_;

  TRACE_EVENTS and do {
    warn "}}} enqueuing alarm '$state' for ", {% ssid %}, "\n";
  };

  if (exists $self->[KR_SESSIONS]->{$session}) {
    my $kr_alarms = $self->[KR_ALARMS];

    # Special case: No alarms in the queue.  Put the new alarm in the
    # queue, and be done with it.
    unless (@$kr_alarms) {
      $kr_alarms->[0] = {% state_to_enqueue %};
    }

    # Special case: New state belongs at the end of the queue.  Push
    # it, and be done with it.
    elsif ($time >= $kr_alarms->[-1]->[ST_TIME]) {
      push @$kr_alarms, {% state_to_enqueue %};
    }

    # Special case: New state comes before earliest state.  Unshift
    # it, and be done with it.
    elsif ($time < $kr_alarms->[0]->[ST_TIME]) {
      unshift @$kr_alarms, {% state_to_enqueue %};
    }

    # Special case: Two alarms in the queue.  The new state enters
    # between them, because it's not before the first one or after the
    # last one.
    elsif (@$kr_alarms == 2) {
      splice @$kr_alarms, 1, 0, {% state_to_enqueue %};
    }

    # Small queue.  Perform a reverse linear search on the assumption
    # that (a) a linear search is fast enough on small queues; and (b)
    # most events will be posted for "now" which tends to be towards
    # the end of the queue.
    elsif (@$kr_alarms < 32) {
      my $index = @$kr_alarms;
      while ($index--) {
        if ($time >= $kr_alarms->[$index]->[ST_TIME]) {
          splice @$kr_alarms, $index+1, 0, {% state_to_enqueue %};
          last;
        }
        elsif ($index == 0) {
          unshift @$kr_alarms, {% state_to_enqueue %};
        }
      }
    }

    # And finally, we have this large queue, and the program has
    # already wasted enough time.
    else {
      my $upper = @$kr_alarms - 1;
      my $lower = 0;
      while ('true') {
        my $midpoint = ($upper + $lower) >> 1;

        # Upper and lower bounds crossed.  No match; insert at the
        # lower bound point.
        if ($upper < $lower) {
          splice @$kr_alarms, $lower, 0, {% state_to_enqueue %};
          last;
        }

        # The key at the midpoint is too high.  The element just below
        # the midpoint becomes the new upper bound.
        if ($time < $kr_alarms->[$midpoint]->[ST_TIME]) {
          $upper = $midpoint - 1;
          next;
        }

        # The key at the midpoint is too low.  The element just above
        # the midpoint becomes the new lower bound.
        if ($time > $kr_alarms->[$midpoint]->[ST_TIME]) {
          $lower = $midpoint + 1;
          next;
        }

        # The key matches the one at the midpoint.  Scan towards
        # higher keys until the midpoint points to an element with a
        # higher key.  Insert the new state before it.
        $midpoint++
          while ( ($midpoint < @$kr_alarms) 
                  and ($time == $kr_alarms->[$midpoint]->[ST_TIME])
                );
        splice @$kr_alarms, $midpoint, 0, {% state_to_enqueue %};
        last;
      }
    }

    # If using Tk and the alarm queue now has only one event, then
    # register a Tk timed callback to dispatch it when it becomes due.
    if ( POE_HAS_TK and @{$self->[KR_ALARMS]} == 1 ) {

      if (defined $self->[KR_TK_TIMED]) {
        $self->[KR_TK_TIMED]->cancel();
        $self->[KR_TK_TIMED] = undef;
      }

      my $next_time = $self->[KR_ALARMS]->[0]->[ST_TIME] - time();
      $next_time = 0 if $next_time < 0;
      $self->[KR_TK_TIMED] = $poe_tk_main_window->after( $next_time * 1000,
                                                         \&tk_alarm_callback
                                                       );
    }

    # Manage reference counts.
    {% ses_refcount_inc2 $session, SS_ALCOUNT %}
  }
  else {
    warn ">>>>> ", join('; ', keys(%{$self->[KR_SESSIONS]})), " <<<<<\n";
    croak "can't enqueue alarm($state) for nonexistent session($session)\a\n";
  }
}

#------------------------------------------------------------------------------
# Post a state to the queue.

sub post {
  my ($self, $destination, $state_name, @etc) = @_;

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = {% alias_resolve $destination %};
  {% test_resolve $destination, $session %}

  # Enqueue the state for "now", which simulates FIFO in our
  # time-ordered queue.

  $self->_enqueue_state( $session, $self->[KR_ACTIVE_SESSION],
                         $state_name, ET_USER,
                         \@etc,
                         time(), (caller)[1,2]
                       );
  return 1;
}

#------------------------------------------------------------------------------
# Post a state to the queue for the current session.

sub yield {
  my ($self, $state_name, @etc) = @_;

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  $self->_enqueue_state( $kr_active_session, $kr_active_session,
                         $state_name, ET_USER,
                         \@etc,
                         time(), (caller)[1,2]
                       );
}

#------------------------------------------------------------------------------
# Call a state directly.

sub call {
  my ($self, $destination, $state_name, @etc) = @_;

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = {% alias_resolve $destination %};
  {% test_resolve $destination, $session %}

  # Dispatch the state right now, bypassing the queue altogether.
  # This tends to be a Bad Thing to Do, but it's useful for
  # synchronous events like selects'.

  # -><- The difference between synchronous and asynchronous events
  # should be made more clear in the documentation, so that people
  # have a tendency not to abuse them.  I discovered in xws that that
  # mixing the two types makes it harder than necessary to write
  # deterministic programs, but the difficulty can be ameliorated if
  # programmers set some base rules and stick to them.

  $! = 0;
  return $self->_dispatch_state( $session, $self->[KR_ACTIVE_SESSION],
                                 $state_name, ET_USER,
                                 \@etc,
                                 time(), (caller)[1,2], undef
                               );
}

#------------------------------------------------------------------------------
# Peek at pending alarms.  Returns a list of pending alarms.

sub queue_peek_alarms {
  my ($self) = @_;
  my @pending_alarms;

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  my $alarm_count = $self->[KR_SESSIONS]->{$kr_active_session}->[SS_ALCOUNT];

  foreach my $alarm (@{$self->[KR_ALARMS]}) {
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
  my ($self, $state, $time, @etc) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  # Remove all previous instances of the alarm.
  my $index = scalar(@{$self->[KR_ALARMS]});
  while ($index--) {
    if ( ($self->[KR_ALARMS]->[$index]->[ST_TYPE] & ET_ALARM) &&
         ($self->[KR_ALARMS]->[$index]->[ST_SESSION] == $kr_active_session) &&
         ($self->[KR_ALARMS]->[$index]->[ST_NAME] eq $state)
    ) {
      {% ses_refcount_dec2 $kr_active_session, SS_ALCOUNT %}
      splice(@{$self->[KR_ALARMS]}, $index, 1);
    }
  }

  # If using Tk and the alarm queue is empty, then discard the Tk
  # alarm callback.
  if (POE_HAS_TK and @{$self->[KR_ALARMS]} == 0) {
    # -><- Remove the idle handler.
  }

  # Add the new alarm if it includes a time.
  if ($time) {
    {% clip_time_to_now $time %}
    $self->_enqueue_alarm( $kr_active_session, $kr_active_session,
                           $state, ET_ALARM,
                           [ @etc ],
                           $time, (caller)[1,2]
                         );
  }
}

# Add an alarm without clobbenig previous alarms of the same name.
sub alarm_add {
  my ($self, $state, $time, @etc) = @_;

  {% clip_time_to_now $time %}

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  $self->_enqueue_alarm( $kr_active_session, $kr_active_session,
                         $state, ET_ALARM,
                         [ @etc ],
                         $time, (caller)[1,2]
                       );
}

# Add a delay, which is just an alarm relative to the current time.
sub delay {
  my ($self, $state, $delay, @etc) = @_;
  if (defined $delay) {
    $self->alarm($state, time() + $delay, @etc);
  }
  else {
    $self->alarm($state, 0);
  }
}

# Add a delay without clobbering previous delays of the same name.
sub delay_add {
  my ($self, $state, $delay, @etc) = @_;
  if (defined $delay) {
    $self->alarm_add($state, time() + $delay, @etc);
  }
}

#==============================================================================
# SELECTS
#==============================================================================

sub _internal_select {
  my ($self, $session, $handle, $state, $select_index) = @_;
  my $kr_handles = $self->[KR_HANDLES];

  # Register a select state.
  if ($state) {
    unless (exists $kr_handles->{$handle}) {
      $kr_handles->{$handle} =
        [ $handle,                      # HND_HANDLE
          0,                            # HND_REFCOUNT
          [ 0, 0, 0 ],                  # HND_VECCOUNT (VEC_RD, VEC_WR, VEC_EX)
          [ { }, { }, { } ],            # HND_SESSIONS (VEC_RD, VEC_WR, VEC_EX)
          fileno($handle)               # HND_FILENO
        ];

      # For DOSISH systems like OS/2
      binmode($handle);

      # Make the handle stop blocking, the Windows way.
      if ($^O eq 'MSWin32') {
        my $set_it = "1";

        # 126 is FIONBIO
        ioctl($handle, 126 | (ord('f')<<8) | (4<<16) | 0x80000000, $set_it)
          or croak "Can't set the handle non-blocking: $!\n";
      }

      # Make the handle stop blocking, the POSIX way.
      else {
        my $flags = fcntl($handle, F_GETFL, 0)
          or croak "fcntl fails with F_GETFL: $!\n";
        $flags = fcntl($handle, F_SETFL, $flags | O_NONBLOCK)
          or croak "fcntl fails with F_SETFL: $!\n";
      }

      # This depends heavily on socket.ph, or somesuch.  It's
      # extremely unportable.  I can't begin to figure out a way to
      # make this work everywhere, so I'm not even going to try.
      #
      # setsockopt($handle, SOL_SOCKET, &TCP_NODELAY, 1)
      #   or die "Couldn't disable Nagle's algorithm: $!\a\n";

      # Turn off buffering.
      select((select($handle), $| = 1)[0]);
    }

    # KR_HANDLES
    my $kr_handle = $kr_handles->{$handle};

    # If this session hasn't already been watching the filehandle,
    # then modify the handle's reference counts and perhaps turn on
    # the appropriate select bit.

    unless (exists $kr_handle->[HND_SESSIONS]->[$select_index]->{$session}) {

      # Increment the handle's vector (Read, Write or Expedite)
      # reference count.  This helps the kernel know when to manage
      # the handle's corresponding vector bit.

      $kr_handle->[HND_VECCOUNT]->[$select_index]++;

      # If this is the first session to watch the handle, then turn
      # its select bit on.

      if ($kr_handle->[HND_VECCOUNT]->[$select_index] == 1) {
        vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 1;

        # If we're using Tk, then we tell it to watch this filehandle
        # for us.  This is in lieu of our own select code.

        if (POE_HAS_TK) {

          # The Tk documentation implies by omission that expedited
          # filehandles aren't, uh, handled.  This is part 1 of 2.

          confess "Tk does not support expedited filehandles"
            if $select_index == VEC_EX;

          $poe_tk_main_window->fileevent
            ( $handle,

              # It can only be VEC_RD or VEC_WR here (VEC_EX is
              # checked a few lines up).
              ( ( $select_index == VEC_RD ) ? 'readable' : 'writable' ),

              [ \&tk_select_callback, $handle, $select_index ],
            );
        }
      }

      # Increment the handle's overall reference count (which is the
      # sum of its read, write and expedite counts but kept separate
      # for faster runtime checking).

      $kr_handle->[HND_REFCOUNT]++;
    }

    # Record the session parameters in the kernel's handle structure,
    # so we know what to do when the watcher unblocks.  This
    # overwrites a previous value, if any, or adds a new one.

    $kr_handle->[HND_SESSIONS]->[$select_index]->{$session} =
      [ $handle, $session, $state ];

    # SS_HANDLES
    my $kr_session = $self->[KR_SESSIONS]->{$session};

    # If the session hasn't already been watching the filehandle, then
    # register the filehandle in the session's structure.

    unless (exists $kr_session->[SS_HANDLES]->{$handle}) {
      $kr_session->[SS_HANDLES]->{$handle} = [ $handle, 0, [ 0, 0, 0 ] ];
      {% ses_refcount_inc $session %}
    }

    # Modify the session's handle structure's reference counts, so the
    # session knows it has a reason to live.

    my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
    unless ($ss_handle->[SH_VECCOUNT]->[$select_index]) {
      $ss_handle->[SH_VECCOUNT]->[$select_index] = 1;
      $ss_handle->[SH_REFCOUNT]++;
    }
  }

  # Remove a select from the kernel, and possibly trigger the
  # session's destruction.

  else {
    # KR_HANDLES

    # Make sure the handle is deregistered with the kernel.

    if (exists $kr_handles->{$handle}) {
      my $kr_handle = $kr_handles->{$handle};

      # Make sure the handle was registered to the requested session.

      if (exists $kr_handle->[HND_SESSIONS]->[$select_index]->{$session}) {

        # Remove the handle from the kernel's session record.

        delete $kr_handle->[HND_SESSIONS]->[$select_index]->{$session};

        # Decrement the handle's reference count.

        $kr_handle->[HND_VECCOUNT]->[$select_index]--;
        ASSERT_REFCOUNT and do {
          die if ($kr_handle->[HND_VECCOUNT]->[$select_index] < 0);
        };

        # If the "vector" count drops to zero, then stop selecting the
        # handle.

        unless ($kr_handle->[HND_VECCOUNT]->[$select_index]) {
          vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 0;

          # If we're using Tk, then we tell it to stop watching this
          # filehandle for us.  This is is lieu of our own select
          # code.

          if (POE_HAS_TK) {

            # The Tk documentation implies by omission that expedited
            # filehandles aren't, uh, handled.  This is part 2 of 2.

            confess "Tk does not support expedited filehandles"
              if $select_index == VEC_EX;

warn "closing";

            $poe_tk_main_window->fileevent
              ( $handle,

                # It can only be VEC_RD or VEC_WR here (VEC_EX is
                # checked a few lines up).
                ( ( $select_index == VEC_RD ) ? 'readable' : 'writable' ),

                # Nothing here!  Callback all gone!
                ''

              );

warn "closed";

          }

          # Shrink the bit vector by chopping zero octets from the
          # end.  Octets because that's the minimum size of a bit
          # vector chunk that Perl manages.  Always keep at least one
          # octet around, even if it's 0.

          $self->[KR_VECTORS]->[$select_index] =~ s/(.)\000+$/$1/;
        }

        # Decrement the kernel record's handle reference count.  If
        # the handle is done being used, then delete it from the
        # kernel's record structure.  This initiates Perl's garbage
        # collection on it, as soon as whatever else in "user space"
        # frees it.

        $kr_handle->[HND_REFCOUNT]--;
        ASSERT_REFCOUNT and do {
          die if ($kr_handle->[HND_REFCOUNT] < 0);
        };
        unless ($kr_handle->[HND_REFCOUNT]) {
          delete $kr_handles->{$handle};
        }

      }
    }

    # SS_HANDLES - Remove the select from the session, assuming there
    # is a session to remove it from.

    my $kr_session = $self->[KR_SESSIONS]->{$session};
    if (exists $kr_session->[SS_HANDLES]->{$handle}) {

      # Remove it from the session's read, write or expedite vector.

      my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
      if ($ss_handle->[SH_VECCOUNT]->[$select_index]) {

        # Hmm... what is this?  Was POE going to support multiple selects?

        $ss_handle->[SH_VECCOUNT]->[$select_index] = 0;

        # Decrement the reference count, and delete the handle if it's done.

        $ss_handle->[SH_REFCOUNT]--;
        ASSERT_REFCOUNT and do {
          die if ($ss_handle->[SH_REFCOUNT] < 0);
        };
        unless ($ss_handle->[SH_REFCOUNT]) {
          delete $kr_session->[SS_HANDLES]->{$handle};
          {% ses_refcount_dec $session %}
        }
      }
    }
  }
}

# "Macro" select that manipulates read, write and expedite selects
# together.
sub select {
  my ($self, $handle, $state_r, $state_w, $state_e) = @_;
  my $session = $self->[KR_ACTIVE_SESSION];
  $self->_internal_select($session, $handle, $state_r, VEC_RD);
  $self->_internal_select($session, $handle, $state_w, VEC_WR);
  $self->_internal_select($session, $handle, $state_e, VEC_EX);
}

# Only manipulate the read select.
sub select_read {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, 0);
};

# Only manipulate the write select.
sub select_write {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, 1);
};

# Only manipulate the expedite select.
sub select_expedite {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, 2);
};

# Turn off a handle's write vector bit without doing
# garbage-collection things.
sub select_pause_write {
  my ($self, $handle) = @_;

  {% validate_handle $handle, VEC_WR %}

  # Turn off the select vector's write bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.

  vec($self->[KR_VECTORS]->[VEC_WR], fileno($handle), 1) = 0;

  if (POE_HAS_TK) {
    $poe_tk_main_window->fileevent
      ( $handle,
        'writable',
        ''
      );
  }

  return 1;
}

# Turn on a handle's write vector bit without doing garbage-collection
# things.
sub select_resume_write {
  my ($self, $handle) = @_;

  {% validate_handle $handle, VEC_WR %}

  # Turn off the select vector's write bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.

  vec($self->[KR_VECTORS]->[VEC_WR], fileno($handle), 1) = 1;

  if (POE_HAS_TK) {
    $poe_tk_main_window->fileevent
      ( $handle,
        'writable',
        [ \&tk_select_callback, $handle, VEC_WR ],
      );
  }

  return 1;
}

#==============================================================================
# ALIASES
#==============================================================================

sub alias_set {
  my ($self, $name) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  # Don't overwrite another session's alias.
  if (exists $self->[KR_ALIASES]->{$name}) {
    if ($self->[KR_ALIASES]->{$name} != $kr_active_session) {
      $! = EEXIST;
      return 0;
    }
    return 1;
  }

  $self->[KR_ALIASES]->{$name} = $kr_active_session;
  $self->[KR_SESSIONS]->{$kr_active_session}->[SS_ALIASES]->{$name} = 1;

  {% ses_refcount_inc $kr_active_session %}

  return 1;
}

# Public interface for removing aliases.
sub alias_remove {
  my ($self, $name) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  unless (exists $self->[KR_ALIASES]->{$name}) {
    $! = ESRCH;
    return 0;
  }

  if ($self->[KR_ALIASES]->{$name} != $kr_active_session) {
    $! = EPERM;
    return 0;
  }

  {% remove_alias $kr_active_session, $name %}

  return 1;
}

sub alias_resolve {
  my ($self, $name) = @_;
  my $session = {% alias_resolve $name %};
  $! = ESRCH unless defined $session;
  $session;
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
# moot now that alias_resolve does it too.  This explicit call will be
# faster, though.

sub ID_id_to_session {
  my ($self, $id) = @_;
  if (exists $self->[KR_SESSION_IDS]->{$id}) {
    $! = 0;
    return $self->[KR_SESSION_IDS]->{$id};
  }
  $! = ESRCH;
  return undef;
}

# Resolve a session reference to its corresponding ID.

sub ID_session_to_id {
  my ($self, $session) = @_;
  if (exists $self->[KR_SESSIONS]->{$session}) {
    $! = 0;
    return $self->[KR_SESSIONS]->{$session}->[SS_ID];
  }
  $! = ESRCH;
  return undef;
}

#==============================================================================
# Extra reference counts, to keep sessions alive when things occur.
# They take session IDs because they may be called from resources at
# times where the session reference is otherwise unknown.  This is
# experimental until the Tk support is definitely working.
#==============================================================================

sub refcount_increment {
  my ($self, $session_id, $tag) = @_;
  my $session = $self->ID_id_to_session( $session_id );
  if (defined $session) {

    # Increment the tag's count for the session.  If this is the first
    # time the tag's been used for the session, then increment the
    # session's reference count as well.

    if (++$self->[KR_SESSIONS]->{$session}->[SS_EXTRA_REFS]->{$tag} == 1) {
      {% ses_refcount_inc $session %}
    }

    TRACE_REFCOUNT and do {
      carp( "+++ session $session_id refcount for tag '$tag' incremented to ",
            $self->[KR_SESSIONS]->{$session}->[SS_EXTRA_REFS]->{$tag},
            " (session reference count is at: ",
            $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT],
            ")"
          );
    };
  }
  undef;
}

sub refcount_decrement {
  my ($self, $session_id, $tag) = @_;
  my $session = $self->ID_id_to_session( $session_id );
  if (defined $session) {

    # Decrement the tag's count for the session.  If this was the last
    # time the tag's been used for the session, then decrement the
    # session's reference count as well.

    my $refcount = --$self->[KR_SESSIONS]->{$session}->[SS_EXTRA_REFS]->{$tag};
    ASSERT_REFCOUNT and do {
      carp( "--- session $session_id refcount for tag '$tag' dropped below 0"
          ) if $refcount < 0;
    };

    unless ($refcount) {
      {% remove_extra_reference $session, $tag %}
    }

    TRACE_REFCOUNT and do {
      carp( "--- session $session_id refcount for tag '$tag' decremented to ",
            "$refcount (session reference count is at: ",
            $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT],
            ")"
          );
    };

  }
}

#==============================================================================
# Safe fork and SIGCHLD, theoretically.  In practice, they seem to be
# broken.
#==============================================================================

sub fork {
  my ($self) = @_;

  # Disable the real signal handler.  How to warn?
  $SIG{CHLD} = 'IGNORE' if exists $SIG{CHLD};
  $SIG{CLD}  = 'IGNORE' if exists $SIG{CLD};

  my $new_pid = fork();

  # Error.
  unless (defined $new_pid) {
    return( undef, $!+0, $! ) if wantarray;
    return undef;
  }

  # This is the parent process.
  if ($new_pid) {

    # Remember which session forked the process.  POE will post
    # _signal CHLD at that session if it's still around when the child
    # process exits.

    $self->[KR_PROCESSES]->{$new_pid} = $self->[KR_ACTIVE_SESSION];

    # Remember that the session has a child process.

    $self->[KR_SESSIONS]->{ $self->[KR_ACTIVE_SESSION]
                          }->[SS_PROCESSES]->{$new_pid} = 1;

    # Went from 0 to 1 child processes; start a poll loop.  This uses
    # a very raw, basic form of POE::Kernel::delay.

    if (keys(%{$self->[KR_PROCESSES]}) == 1) {
      $self->_enqueue_state( $self, $self,
                             EN_SCPOLL, ET_SCPOLL,
                             [],
                             time() + 1, (caller)[1,2]
                           );
    }

    return( $new_pid, 0, 0 ) if wantarray;
    return $new_pid;
  }

  # This is the child process.
  else {

    # Build a unique list of sessions that have child processes.

    my %sessions;
    foreach (values %{$self->[KR_PROCESSES]}) {
      $sessions{$_}++;
    }

    # Make these sessions forget that they have child processes.  This
    # will ensure that the real parent process (the parent of this
    # one) reaps the proper children.

    foreach my $session (keys %sessions) {
      $self->[KR_SESSIONS]->{$session}->[SS_PROCESSES] = { };
    }

    # Clean the POE::Kernel child-process table since this is a new
    # process without any children yet.
    $self->[KR_PROCESSES] = { };

    return( 0, 0, 0 ) if wantarray;
    return 0;
  }
}

#==============================================================================
# HANDLERS
#==============================================================================

# Add or remove states from sessions.
sub state {
  my ($self, $state_name, $state_code, $state_alias) = @_;
  $state_alias = $state_name unless defined $state_alias;

  if ( (ref($self->[KR_ACTIVE_SESSION]) ne '') &&
                                        # -><- breaks subclasses... sky has fix
       (ref($self->[KR_ACTIVE_SESSION]) ne 'POE::Kernel')
  ) {
    $self->[KR_ACTIVE_SESSION]->register_state( $state_name,
                                                $state_code,
                                                $state_alias
                                              );
    return 1;
  }
                                        # no such session
  $! = ESRCH;
  return 0;
}

###############################################################################
# Bootstrap the kernel.  This is inherited from a time when multiple
# kernels could be present in the same Perl process.

new POE::Kernel();

###############################################################################
1;

__END__

=head1 NAME

POE::Kernel - POE Event Queue and Resource Manager

=head1 SYNOPSIS

  ### A minimal POE program.

  #!/usr/bin/perl -w
  use strict;              # It's a good idea, anyway.
  use POE;                 # This includes Kernel and Session.
  new POE::Session( ... ); # This is an initial bootstrap Session.
  $poe_kernel->run();      # Run until all sessions exit.
  exit;                    # Program's over.  Be seeing you!

  ### Methods to manage events.

  # Post an event to some session.
  $kernel->post( $session, $state_name, @state_args );

  # Post an event to this session.
  $kernel->yield( $state_name, @state_args );

  # Call a state right now, and return what it returns.  States'
  # return values are always scalars.
  $state_returns = $kernel->call( $session, $state_name, @state_args );

  ### Methods to manage timed events.  These events are dispatched
  ### some time in the future, rather than in FIFO order.

  # Post an event to be delivered at an absolute epoch time.  This
  # clears pending alarms for the same state name.
  $kernel->alarm( $state_name, $epoch_time, @state_args );

  # Post an additional alarm.  This leaves existing alarms for the
  # same state name in the queue.
  $kernel->alarm_add( $state_name, $epoch_time, @state_args );

  # Post an event to be delivered some number of seconds from now.
  # This clears pending delays for the same state name.
  $kernel->delay( $state_name, $seconds, @state_args );

  # Post an additional delay.  This leaves existing delays for the
  # same state name in the queue.
  $kernel->delay_add( $state_name, $seconds, @state_args );

  # Return the state names of pending alarms.
  @state_names = $kernel->queue_peek_alarms( );

  ### Alias management methods.  Aliases are symbolic names for
  ### sessions.  Sessions may have more than one alias.

  # Set an alias for the current session.  Status is either 1 for
  # success or 0 for failure.  If it returs 0, then $! is set to a
  # reason for the failure.
  $status = $kernel->alias_set( $alias );

  # Clear an alias for the current session.  Status is either 1 for
  # success or 0 for failure.  If it returns 0, then $! is set to a
  # reason for the failure.
  $status = $kernel->alias_remove( $alias );

  # Resolve an alias into a session reference.  This is mostly
  # obsolete since most kernel methods perform session resolution
  # internally.  Returns a session reference, or undef on failure.  If
  # it returns undef, then $! is set to a reason for the failure.
  $session_reference = $kernel->alias_resolve( $alias );

  ### Select management methods.  Selects monitor filehandles for
  ### activity.  Select states are called synchronously so they can
  ### immediately deal with the filehandle activity.

  # Invoke a state when a filehandle holds something that can be read.
  $kernel->select_read( $file_handle, $state_name );

  # Clear a previous read select from a filehandle.
  $kernel->select_read( $file_handle );

  # Invoke a state when a filehandle has room for something to be
  # written into it.
  $kernel->select_write( $file_handle, $state_name );

  # Clear a previous write select from a filehandle.
  $kernel->select_write( $file_handle );

  # Invoke a state when a filehandle has out-of-band data to be read.
  $kernel->select_expedite( $file_handle, $state_name );

  # Clear an expedite select from a filehandle.
  $kernel->select_expedite( $file_handle );

  # Set and/or clear a combination of selects in one call.
  $kernel->select( $file_handle,
                   $read_state_name,     # or undef to remove it
                   $write_state_name,    # or undef to remove it
                   $expedite_state_same, # or undef to remove it
                 );

  # Pause a write select.  This temporarily causes an existing write
  # select to ignore filehandle activity.  It has less overhead than
  # select_write( $file_handle ).
  $kernel->select_pause_write( $file_handle );

  # Resume a write select.  This re-enables events from a paused write
  # select.
  $kernel->select_resume_write( $file_handle );

  ### Signal management methods.

  # Post a signal to a particular session.  These "soft" signals are
  # posted through POE's event queue, and they don't involve the
  # underlying operating system.  They are not restricted to the
  # signals that the OS supports; in fact, POE uses fictitious ZOMBIE
  # and IDLE signals internally.
  $kernel->signal( $session, $signal_name );

  # Map a signal name to a state which will handle it.
  $kernel->sig( $signal_name, $handler_state );

  # Clear a signal handler.
  $kernel->sig( $signal_name );

  ### State management methods.  These allow sessions to modify their
  ### states at runtime.  See the POE::Session manpage for details 

  # Add a new inline state, or replace an existing one.
  $kernel->state( $state_name, $code_reference );

  # Add a new object or package state, or replace an existing one.
  # The object method will be the same as the state name.
  $kernel->state( $state_name, $object_ref_or_package_name );

  # Add a new object or package state, or replace an existing one.
  # The object method may be different from the state name.
  $kernel->state( $state_name, $object_ref_or_package_name, $method_name );

  # Remove an existing state.
  $kernel->state( $state_name );

  ### Manage session IDs.  The kernel instance also has an ID since it
  ### acts like a session in many ways.

  # Fetch the kernel's unique ID.
  $kernel_id = $kernel->ID;

  # Resolve an ID into a session reference.  $kernel->alias_resolve
  # has been overloaded to also recognize session IDs, but this is
  # faster.
  $session = $kernel->ID_id_to_session( $id );

  # Resolve a session reference into its ID.  $session->ID is
  # syntactic sugar for this call.
  $id = $kernel->ID_session_to_id( $session );

  ### Manage external reference counts.  This is an experimental
  ### feature.  There is no guarantee that it will work, nor is it
  ### guaranteed to exist in the future.  The functions work by
  ### session ID because session references themselves would hold
  ### reference counts that prevent Perl's garbage collection from
  ### doing the right thing.

  # Increment an external reference count, by name.  These references
  # keep a session alive.
  $kernel->refcount( $session_id, $refcount_name );

  # Decrement an external reference count.
  $kernel->refcount( $session_id, $refcount_name );

  ### Manage processes.  This is an experimental feature.  There is no
  ### guarantee that it will work, nor is it guaranteed to exist in
  ### the future.

  # Fork a process "safely".  It sets up a nonblocking waitpid loop to
  # reap children instead of relying on SIGCH?LD, which is problematic
  # in plain Perl.  It returns whatever fork() would.
  $fork_retval = $kernel->fork();

=head1 DESCRIPTION

This description is out of date as of version 0.1001, but the synopsis
is accurate.  The description will be fixed shortly.

POE::Kernel contains POE's event loop, select logic and resource
management methods.  There can only be one POE::Kernel per process,
and it's created automatically the first time POE::Kernel is used.
This simplifies signal delivery in the present and threads support in
the future.

=head1 EXPORTED SYMBOLS

POE::Kernel exports $poe_kernel, a reference to the program's single
kernel instance.  This mainly is used in the main package, so that
$poe_kernel->run() may be called cleanly.

Sessions' states should endeavor to use $_[KERNEL], since $poe_kernel
may not be available, or it may be different than the kernel actually
invoking the object.

=head1 PUBLIC KERNEL METHODS

POE::Kernel contains methods to manage the kernel itself, sessions,
and resources such as files, signals and alarms.

Many of the public Kernel methods generate events.  Please see the
"PREDEFINED EVENTS AND PARAMETERS" section in POE::Session's
documentation.

Some Kernel methods accept a C<$session> reference.  These allow
events to be dispatched to arbitrary sessions.  For example, a program
can post a state transition event almost anywhere:

  $kernel->post( $destination_session, $state_to_invoke );

On the other hand, there are methods that don't let programs specify
destinations.  The events generated by these methods, if any, will be
dispatched to the current session.  For example, setting an alarm:

  $kernel->alarm( $state_to_invoke, $when_to_invoke_it );

=head2 Kernel Management Methods

=over 4

=item *

POE::Kernel::run()

POE::Kernel::run() starts the kernel's event loop.  It will not return
until all its sessions have stopped.  There are two corollaries to
this rule: It will return immediately if there are no sessions; and if
sessions never exit, neither will run().

=back

=head2 Event Management Methods

Events tell sessions which state to invoke next.  States are defined
when sessions are created.  States may also be added, removed or
changed at runtime by POE::Kernel::state(), which acts on the current
session.

There are a few ways to send events to sessions.  Events can be
posted, in which case the kernel queues them and dispatches them in
FIFO order.  States can also be called immediately, bypassing the
queue.  Immediate calls can be useful for "critical sections"; for
example, POE's I/O abstractions use call() to minimize event latency.

To learn more about events and the information they convey, please see
"PREDEFINED EVENTS AND PARAMETERS" in the POE::Session documentation.

=over 4

=item *

POE::Kernel::post( $destination, $state, @args )

POE::Kernel::post places an event in the kernel's queue.  The kernel
dispatches queued events in FIFO order.  When posted events are
dispatched, their corresponding states are invoked in a scalar
context, and their return values are discarded.  Signal handlers work
differently, but they're not invoked as a result of post().

If a state's return value is important, there are at least two ways to
get it.  First, have the $destination post a return vent to its
$_[SENDER]; second, use POE::Kernel::call() instead.

POE::Kernel::post returns undef on failure, or an unspecified defined
value on success.  $! is set to the reason why the post failed.

=item *

POE::Kernel::yield( $state, @args )

POE::Kernel::yield is an alias for posting an event to the current
session.  It does not immediately swap call stacks like yield() in
real thread libraries might.  If there's a way to do this in perl, I'd
sure like to know.

=item *

POE::Kernel::call( $session, $state, $args )

POE::Kernel::call immediately dispatches an event to a session.
States invoked this way are evaluated in a scalar context, and call()
returns their return values.

call() can exercise bugs in perl and/or the C library (we're not
really sure which just yet).  This only seems to occur when one state
(state1) is destroyed from another state (state0) as a result of
state0 being called from state1.

Until that bug is pinned down and fixed, if your program dumps core
with a SIGSEGV, try changing your call()s to post()s.

call() returns undef on failure.  It may also return undef on success,
if the called state returns success.  What a mess.  call() also sets
$! to 0 on success, regardless of what it's set to in the called
state.

=item *

POE::Kernel::queue_peek_alarms()

Peeks at the current session's event queue, returning a list of
pending alarms.  The list is empty if no alarms are pending.  The
list's order is undefined as of version 0.0904 (it's really in time
order, but that may change).

=back

=head2 Alarm Management Methods

Alarms are just events that are scheduled to be dispatched at some
later time.  POE's queue is a priority queue keyed on time, so these
events go to the appropriate place in the queue.  Posted events are
really enqueued for "now" (defined as whatever time() returns).

If Time::HiRes is available, POE will use it to achieve better
resolution on enqueued events.

=over 4

=item *

POE::Kernel::alarm( $state, $time, @args )

The alarm() method enqueues an event for the current session with a
future dispatch time, specified in seconds since whatever epoch time()
uses (usually the UNIX epoch).  If $time is in the past, it will be
clipped to time(), making the alarm() call synonymous to post() but
with some extra overhead.

alarm() ensures that its alarm is the only one queued for the current
session and given state.  It does this by scouring the queue and
removing all others matching the combination of session and state.  As
of 0.0908, the alarm_add() method can post additional alarms without
scouring previous ones away.

@args are passed to the alarm handler as C<@_[ARG0..$#_]>.

It is possible to remove alarms from the queue by posting an alarm
without additional parameters.  This triggers the queue scour without
posting an alarm.  For example:

  $kernel->alarm( $state ); # Removes the alarm for $state

As of version 0.0904, the alarm() function will only remove alarms.
Other types of events will remain in the queue.

=item *

POE::Kernel::alarm_add( $state, $time, @args )

The alarm_add() method enqueues an event for the current session with
a future dispatch time, specified in seconds since whatever epoch
time() uses (usually the UNIX epoch).  If $time is in the past, it
will be clipped to time(), making the alarm_add() call synonymous to
post() but with some extra overhead.

Unlike alarm(), however, it does not scour the queue for previous
alarms matching the current session/state pair.  Since it doesn't
scour, adding an empty alarm won't clear others from the queue.

This function may be faster than alarm() since the scour phase is
skipped.

=item *

POE::Kernel::delay( $state, $seconds, @args )

The delay() method is an alias for:

  $kernel->alarm( $state, time() + $seconds, @args );

However it silently uses Time::HiRes if it's available, so time()
automagically has an increased resolution when it can.  This saves
programs from having to figure out whether Time::HiRes is available
themselves.

All the details for POE::Kernel::alarm() apply to delay() as well.
For example, delays may be removed by omitting the $seconds and @args
parameters:

  $kernel->delay( $state ); # Removes the delay for $state

As of version 0.0904, the delay() function will only remove alarms.
Other types of events will remain in the queue.

=item *

POE::Kernel::delay_add( $state, $seconds, @args )

The delay_add() method works like delay(), but it allows duplicate
alarms.  It is equivalent to:

  $kernel->alarm_add( $state, time() + $seconds, @args );

The "empty delay" syntax is meaningless since alarm_add() does not
scour the queue for duplicates.

This function may be faster than delay() since the scour phase is
skipped.

=back

=head2 Alias Management Methods

Aliases allow sessions to be referenced by name instead of by session
reference.  They also allow sessions to remain active without having
selects or events.  This provides support for "daemon" sessions that
act as resources but don't necessarily have resources themselves.

Aliases must be unique.  Sessions may have more than one alias.

=over 4

=item *

POE::Kernel::alias_set( $alias )

The alias_set() method sets an alias for the current session.

It returns 1 on success.  On failure, it returns 0 and sets $! to one
of:

  EEXIST - The alias already exists for another session.

=item *

POE::Kernel::alias_remove( $alias )

The alias_remove() method removes an alias for the current session.

It returns 1 on success.  On failure, it returns 0 and sets $! to one
of:

  ESRCH - The alias does not exist.
  EPERM - The alias belongs to another session.

=item *

POE::Kernel::alias_resolve( $alias )

The alias_resolve() method returns a session reference corresponding
to the given alias.  POE::Kernel does this internally, so it's usually
not necessary.

It returns a session reference on success.  On failure, it returns
undef and sets $! to one of:

  ESRCH - The alias does not exist.

$kernel->alias_resolve($alias) has been overloaded to resolve several
things into session references.  Each of these things may be used
instead of a session reference in other kernel method calls.

The things, in order, are:

Session references: Yes, this is redundant, but it also means that you
can use stringified session references as event destinations.  That
provides a form of weak session reference, which can be handy, but
note: Perl reuses references rather quickly, so programs should
probably use session IDs instead.

Session IDs: Every session is given a unique numeric ID, similar to an
operating system's process ID.  There never will be two sessions with
the same ID at the same time, and the rate of reuse is extremely low
(the ID is a Perl integer, which tends to be really really large).
These supply a different sort of weak reference for sessions.

Aliases: These are the ones registered by alias_set.

Heap references: Once upon a time $_[HEAP] was used in place of
$_[SESSION].  This is SEVERELY depreciated now, and programs will spew
warnings every time it's done.

=back

=head2 Select Management Methods

Selects are file handle monitors.  They generate events to indicate
when activity occurs on the file handles they watch.  POE keeps track
of how many selects are watching a file handle, and it will close the
file when nobody is looking at it.

There are three types of select.  Each corresponds to one of the bit
vectors in Perl's four-argument select() function.  "Read" selects
generate events when files become ready for reading.  "Write" selects
generate events when files are available to be written to.  "Expedite"
selects generate events when files have out-of-band information to be
read.

=over 4

=item *

POE::Kernel::select( $filehandle, $rd_state, $wr_state, $ex_state )

The select() method manipulates all three selects for a file handle at
the same time.  Selects are added for each defined state, and selects
are removed for undefined states.

=item *

POE::Kernel::select_read( $filehandle, $read_state )
POE::Kernel::select_write( $filehandle, $write_state )
POE::Kernel::select_expedite( $filehandle, $expedite_state )

These methods add, remove or change the state that is called when a
filehandle becomes ready for reading, writing, or out-of-band reading,
respectively.  They work like POE::Kernel::select, except they allow
individual aspects of a filehandle to be changed.

If the state parameter is undefined, then the filehandle watcher is
removed; otherwise it's added or changed.  These functions have a
moderate amount of overhead, since they update POE::Kernel's
reference-counting structures.

=item *

POE::Kernel::select_pause_write( $filehandle );
POE::Kernel::select_resume_write( $filehandle );

These methods allow a write select to be paused and resumed without
the overhead of maintaining POE::Kernel's reference-counting
structures.

It is most useful for write select handlers that may need to pause
write-okay events when their outbound buffers are empty and resume
them when new output is enqueued.

=back

=head2 Signal Management Methods

The POE::Session documentation has more information about B<_signal>
events.

POE currently does not make Perl's signals safe.  Using signals is
okay in short-lived programs, but long-uptime servers may eventually
dump core if they receive a lot of signals.  POE provides a "safe"
fork() function that periodically reaps children without using
signals; it emulates the system's SIGCHLD signal for each process in
reaps.

Mileage varies considerably.

The kernel generates B<_signal> events when it receives signals from
the operating system.  Sessions may also send signals between
themselves without involving the OS.

The kernel determines whether or not signals have been handled by
looking at B<_signal> states' return values.  If the state returns
logical true, then it means the signal was handled.  If it returns
false, then the kernel assumes the signal wasn't handled.

POE will stop sessions that don't handle some signals.  These
"terminal" signals are QUIT, INT, KILL, TERM, HUP, and the fictitious
IDLE signal.

POE broadcasts SIGIDLE to all sessions when the kernel runs out of
events to dispatch, and when there are no alarms or selects to
generate new events.

Finally, there is one fictitious signal that always stops a session:
ZOMBIE.  If the kernel remains idle after SIGIDLE is broadcast, then
SIGZOMBIE is broadcast to force reaping of zombie sessions.  This
tells these sessions (usually aliased "daemon" sessions) that nothing
is left to do, and they're as good as dead anyway.

It's normal for aliased sessions to receive IDLE and ZOMBIE when all
the sessions that may use them have gone away.

=over 4

=item *

POE::Kernel::sig( $signal_name, $state_name )

The sig() method registers a state to handle a particular signal.
Only one state in any given session may be registered for a particular
signal.  Registering a second state for the same signal will replace
the previous state with the new one.

Signals that don't have states will be dispatched to the _signal state
instead.

=item *

POE::Kernel::signal( $session, $signal_name, @args )

The signal() method posts a signal event to a session.  It uses the
kernel's event queue, bypassing the operating system, so the signal's
name is not limited to what the OS allows.  For example, the kernel
does something similar to post a fictitious ZOMBIE signal:

  $kernel->signal($session, 'ZOMBIE');

=back

=head2 Process Management Methods

POE's signal handling is Perl's signal handling, which means that POE
won't safely handle signals as long as Perl has a problem with them.

However, POE works around this in at least SIGCHLD's case by providing
a "safe" fork() function.  &POE::Kernel::fork() blocks
$SIG{'CHLD','CLD'} and starts an event loop to poll for expired child
processes.  It emulates the system's SIGCHLD behavior by sending a
"soft" CHLD signal to the appropriate session.

Because POE knows which session called its version of fork(), it can
signal just that session that its forked child process has completed.

B<Note:> The first &POE::Kernel::fork call disables POE's usual
SIGCHLD handler, so that the poll loop can reap children safely.
Mixing plain fork and &POE::Kernel::fork isn't recommended.

=over 4

=item *

POE::Kernel::fork( )

The fork() method tries to fork a process in the usual Unix way.  In
addition, it blocks SIGCHLD and/or SIGCLD and starts an event loop to
poll for completed child processes.

POE's fork() will return different things in scalar and list contexts.
In scalar context, it returns the child PID, 0, or undef, just as
Perl's fork() does.  In a list context, it returns three items: the
child PID (or 0 or undef), the numeric version of $!, and the string
version of $!.

=back

=head2 State Management Methods

The kernel's state management method lets sessions add, change and
remove states at runtime.  Wheels use this to add and remove select
states from sessions when they're created and destroyed.

=over 4

=item *

POE::Kernel::state( $state_name, $code_reference )
POE::Kernel::state( $method_name, $object_reference )
POE::Kernel::state( $function_name, $package_name )
POE::Kernel::state( $state_name, $obj_or_package_ref, $method_name )

The state() method has three different uses, each for adding, updating
or removing a different kind of state.  It manipulates states in the
current session.

The three-parameter version of state() registers an object or package
state to a method with a different name.  Normally the object or
package method would need to be named after the state it catches.

The state() method returns 1 on success.  On failure, it returns 0 and
sets $! to one of:

  ESRCH - Somehow, the current session does not exist.

This function can only register or remove one state at a time.

=over 2

=item *

Inline States

Inline states are manipulated with:

  $kernel->state($state_name, $code_reference);

If $code_reference is undef, then $state_name will be removed.  Any
pending events destined for $state_name will be redirected to
_default.

=item *

Object States

Object states are manipulated with:

  $kernel->state($method_name, $object_reference);

If $object_reference is undef, then the $method_name state will be
removed.  Any pending events destined for $method_name will be
redirected to _default.

They can also be maintained with:

  $kernel->state($state_name, $object_reference, $object_method);

For example, this maps a session's B®_start¯ state to the object's
start_state method:

  $kernel->state('_start', $object_reference, 'start_state');

=item *

Package States

Package states are manipulated with:

  $kernel->state($function_name, $package_name);

If $package_name is undef, then the $function_name state will be
removed.  Any pending events destined for $function_name will be
redirected to _default.

=back

=back

=head2 ID Management Methods

POE generates a unique ID for the process, and it maintains unique
serial numbers for every session.  These functions retrieve various ID
values.

=over 4

=item *

POE::Kernel::ID()

Returns a unique ID for this POE process.

  my $process_id = $kernel->ID();

=item *

POE::Kernel::ID_id_to_session( $id );

This function is depreciated.  Please see alias_resolve.

Returns a session reference for the given ID.  It returns undef if the
ID doesn't exist.  This allows programs to uniquely identify a
particular Session (or detect that it's gone) even if Perl reuses the
Session reference later.

=item *

POE::Kernel::ID_session_to_id( $session );

Returns an ID for the given POE::Session reference, or undef ith the
session doesn't exist.

Perl reuses Session references fairly frequently, but Session IDs are
unique.  Because of this, the ID of a given reference (stringified, so
Perl can release the referenced Session) may appear to change.  If it
does appear to have changed, then the Session reference is probably
invalid.

=back

=head1 DEBUGGING FLAGS

These flags were made public in 0.0906.  If they are pre-defined by
the first package that uses POE::Kernel (or POE, since that includes
POE::Kernel by default), then the pre-definition will take precedence
over POE::Kernel's definition.  In this way, it is possible to use
POE::Kernel's internal debugging code without finding Kernel.pm and
editing it.

Debugging flags are meant to be constants.  They should be prototyped
as such, and they must be declared in the POE::Kernel package.

Sample usage:

  # Display information about garbage collection, and display some
  # profiling information at the end.
  sub POE::Kernel::TRACE_GARBAGE   () { 1 }
  sub POE::Kernel::ASSERT_REFCOUNT () { 1 }
  use POE;
  ...

=over 4

=item *

TRACE_DEFAULT

The value of TRACE_DEFAULT, which itself defaults to 0, is used as the
default value for all the other TRACE_* constants.

=item *

TRACE_QUEUE

Enables a runtime trace of POE's main event loop.

=item *

TRACE_PROFILE

Enables a runtime count of the events that have been dispatched and an
end-run report of the collected statistics.

=item *

TRACE_SELECT

Displays a runtime trace of select's arguments and return values.

=item *

TRACE_EVENTS

Displays a runtime trace of events as they're enqueued and dispatched.

=item *

TRACE_GARBAGE

Displays a runtime trace of garbage checking and collecting.

=item *

ASSERT_DEFAULT

The value of ASSERT_DEFAULT, which itself defaults to 0, is used as
the default value for all the other ASSERT_* constants.  POE's t/*.t
tests enable ASSERT_DEFAULT to turn on maximum error checking.

=item *

ASSERT_SELECT

Causes POE to check for and die on fatal select() errors.

=item *

ASSERT_GARBAGE

Enables a bunch of reference count checking during garbage collection.
This verifies the state of POE's internal data structures.

=item *

ASSERT_RELATIONS

Ensures that sessions' parent/child relationships are consistent.

=item *

ASSERT_SESSIONS

Makes bad session references fatal.  This can be helpful in situations
where sessions aren't running as expected.

=item *

ASSERT_REFCOUNT

Dies if reference counts go negative.  This is another internal
consistency check on POE's data structures.

=back

=head1 SEE ALSO

POE; POE::Session

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
