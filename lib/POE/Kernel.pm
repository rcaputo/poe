# $Id$

package POE::Kernel;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use POE::Queue::Array;
use POSIX qw(fcntl_h sys_wait_h);
use Errno qw(ESRCH EINTR ECHILD EPERM EINVAL EEXIST EAGAIN EWOULDBLOCK);
use Carp qw(carp croak confess cluck);
use Sys::Hostname qw(hostname);
use IO::Handle;

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
  { no strict 'refs';

    # Allow users to turn off Time::HiRes usage for whatever reason.
    my $time_hires_default = 1;
    $time_hires_default = $ENV{USE_TIME_HIRES} if defined $ENV{USE_TIME_HIRES};
    if (defined &USE_TIME_HIRES) {
      $time_hires_default = USE_TIME_HIRES();
    }
    else {
      eval "sub USE_TIME_HIRES () { $time_hires_default }";
    }
  }
  eval {
    require Time::HiRes;
    Time::HiRes->import(qw(time sleep));
  } if USE_TIME_HIRES();

  # Provide dummy constants so things at least compile.

  if (RUNNING_IN_HELL) {
    eval '*F_GETFL = sub { 0 };';
    eval '*F_SETFL = sub { 0 };';
  }
}

#==============================================================================
# Globals, or at least package-scoped things.  Data structurse were
# moved into lexicals in 0.1201.

# A flag determining whether there are child processes.  Starts true
# so our waitpid() loop can run at least once.  Starts false when
# running in an Apache handler so our SIGCHLD hijinx don't interfere
# with the web server.
my $kr_child_procs = exists($INC{'Apache.pm'}) ? 0 : 1;

# A reference to the currently active session.  Used throughout the
# functions that act on the current session.
my $kr_active_session;
my $kr_active_event;

# The Kernel's master queue.
my $kr_queue;

# Filehandle activity modes.  They are often used as list indexes.
sub MODE_RD () { 0 }  # read
sub MODE_WR () { 1 }  # write
sub MODE_EX () { 2 }  # exception/expedite

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
sub EN_STAT   () { '_stat_tick'       }

# These are POE's event classes (types).  They often shadow the event
# names themselves, but they can encompass a large group of events.
# For example, ET_ALARM describes anything enqueued as by an alarm
# call.  Types are preferred over names because bitmask tests are
# faster than sring equality tests.

sub ET_POST   () { 0x0001 }  # User events (posted, yielded).
sub ET_CALL   () { 0x0002 }  # User events that weren't enqueued.
sub ET_START  () { 0x0004 }  # _start
sub ET_STOP   () { 0x0008 }  # _stop
sub ET_SIGNAL () { 0x0010 }  # _signal
sub ET_GC     () { 0x0020 }  # _garbage_collect
sub ET_PARENT () { 0x0040 }  # _parent
sub ET_CHILD  () { 0x0080 }  # _child
sub ET_SCPOLL () { 0x0100 }  # _sigchild_poll
sub ET_ALARM  () { 0x0200 }  # Alarm events.
sub ET_SELECT () { 0x0400 }  # File activity events.
sub ET_STAT   () { 0x0800 }  # Statistics gathering

# A mask for all events generated by/for users.
sub ET_MASK_USER () { ~(ET_GC | ET_SCPOLL | ET_STAT) }

# Temporary signal subtypes, used during signal dispatch semantics
# deprecation and reformation.

sub ET_SIGNAL_EXPLICIT   () { 0x0800 }  # Explicitly requested signal.
sub ET_SIGNAL_COMPATIBLE () { 0x1000 }  # Backward-compatible semantics.

# A hash of reserved names.  It's used to test whether someone is
# trying to use an internal event directoly.  XXX - These are not fat
# commas, otherwise the symbolic constants would be stringified.

my %poes_own_events =
  ( EN_CHILD  , 1, EN_GC     , 1, EN_PARENT , 1, EN_SCPOLL , 1,
    EN_SIGNAL , 1, EN_START  , 1, EN_STOP   , 1, EN_STAT,    1,
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
    next if defined *{"TRACE_$name"}{CODE};
    my $trace_value = &TRACE_DEFAULT;
    eval "sub TRACE_$name () { $trace_value }";
    die if $@;
  }
}

# Shorthand for defining an assert constant.
sub define_assert {
  no strict 'refs';
  foreach my $name (@_) {
    next if defined *{"ASSERT_$name"}{CODE};
    my $assert_value = &ASSERT_DEFAULT;
    eval "sub ASSERT_$name () { $assert_value }";
    die if $@;
  }
}

# Debugging flags for subsystems.  They're done as double evals here
# so that someone may define them before using POE::Kernel (or POE),
# and the pre-defined value will take precedence over the defaults
# here.

BEGIN {

  # Assimilate POE_TRACE_* and POE_ASSERT_* environment variables.
  # Environment variables override everything else.
  while (my ($var, $val) = each %ENV) {
    next unless $var =~ /^POE_((?:TRACE|ASSERT)_[A-Z_]+)$/;
    my $const = $1;

    # Copy so we don't hurt our environment.  Make sure strings are
    # wrapped in quotes.
    my $value = $val;
    $value =~ tr['"][]d;
    $value = qq("$value") if $value =~ /\D/;

    no warnings;
    eval "sub $const () { $value }";
    die if $@;
  }

  # TRACE_FILENAME is special.
  {
    no strict 'refs';
    my $trace_filename = TRACE_FILENAME() if defined &TRACE_FILENAME;
    if (defined $trace_filename) {
      open TRACE_FILE, ">$trace_filename"
        or die "can't open trace file `$trace_filename': $!";
      CORE::select((CORE::select(TRACE_FILE), $| = 1)[0]);
    }
    else {
      *TRACE_FILE = *STDERR;
    }
  }

  # TRACE_DEFAULT changes the default value for other TRACE_*
  # constants.  Since define_trace() uses TRACE_DEFAULT internally, it
  # can't be used to define TRACE_DEFAULT itself.

  defined &TRACE_DEFAULT or eval "sub TRACE_DEFAULT () { 0 }";

  define_trace qw(
    EVENTS FILES PROFILE REFCNT RETVALS SESSIONS SIGNALS STATISTICS
  );

  # See the notes for TRACE_DEFAULT, except read ASSERT and assert
  # where you see TRACE and trace.

  defined &ASSERT_DEFAULT or eval "sub ASSERT_DEFAULT () { 0 }";

  define_assert qw(DATA EVENTS FILES RETVALS USAGE);
}

# This is a second BEGIN block so TRACE_STATISTICS may be defined
# already.

BEGIN {
  # The Kernel's queue is "idle" if there is one or two events in it.
  # One event is for the signal poller; a second event is for the
  # profiler timer tick, if TRACE_PROFILE is enabled.

  my $idle_queue_size = 1;
  $idle_queue_size++ if TRACE_PROFILE;
  eval "sub IDLE_QUEUE_SIZE () { $idle_queue_size }";
  die if $@;
};

#------------------------------------------------------------------------------
# Helpers to carp, croak, confess, cluck, warn and die with whatever
# trace file we're using today.  _trap is reserved for internal
# errors.

sub _trap {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;
  confess(
    "Please mail the following information to bug-POE\@rt.cpan.org:\n@_"
  );
}

sub _croak {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;
  croak @_;
}

sub _confess {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;
  confess @_;
}

sub _cluck {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;
  cluck @_;
}

sub _carp {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;
  carp @_;
}

sub _warn {
  my ($package, $file, $line) = caller();
  my $message = join("", @_);
  $message .= " at $file line $line\n" unless $message =~ /\n$/;
  local *STDERR = *TRACE_FILE;
  warn $message;
}

sub _die {
  my ($package, $file, $line) = caller();
  my $message = join("", @_);
  $message .= " at $file line $line\n" unless $message =~ /\n$/;
  local *STDERR = *TRACE_FILE;
  die $message;
}

#------------------------------------------------------------------------------
# Adapt POE::Kernel's personality to whichever event loop is present.

BEGIN {
  my $used_first;

  # First see if someone has loaded a POE::Loop or XS version
  # explicitly.  Make a note of it if they already have.  The next
  # loop through %INC will just verify that two loops aren't active at
  # once.
  foreach my $file (keys %INC) {
    if ($file =~ /^POE\/(?:XS\/)?Loop\/(.+)\.pm$/) {
      $used_first = $1;
    }
  }

  foreach my $file (keys %INC) {
    # Remove IO/ so we can load POE::Loop::Poll instead of
    # POE::Loop::IO/Poll.
    #
    # TODO - A better convention would be to replace the path
    # separators with hyphens and rename Loop/Poll.pm to
    # Loop/IO-Poll.pm.  Foresight > Hindsight.
    my $pared_file = $file;
    $pared_file =~ s/^IO\///;
    next if $pared_file =~ /\//;

    my $module = $pared_file;
    substr($module, -3) = "";

    # Modules can die with "not really dying" if they've loaded
    # something else.  This exception prevents the rest of the
    # originally used module from being parsed, so the module it's
    # handed off to takes over.

    # Try for the XS version first.  If it fails, try the plain
    # version.  If that fails, we're up a creek.
    my $mod = "POE::XS::Loop::$module";
    eval "require $mod";
    if ($@ =~ /^Can't locate/) {
      $mod = "POE::Loop::$module";
      eval "require $mod";
    }

    next if $@ =~ /^Can't locate/;
    die if $@ and $@ !~ /not really dying/;

    if (defined $used_first and $used_first ne $module) {
      die(
        "*\n",
        "* POE can't use multiple event loops at once.\n",
        "* You used $used_first and $module.\n",
        "*\n",
      );
    }

    $used_first = $module;
  }

  unless (defined $used_first) {
    $used_first = "POE::XS::Loop::Select";
    eval "require $used_first";
    if ($@ and $@ =~ /^Can't locate/) {
      $used_first =~ s/XS:://;
      eval "require $used_first";
    }
    if ($@) {
      die(
        "*\n",
        "* POE can't use $used_first:\n",
        "* $@\n",
        "*\n",
      );
    }
  }
}

#------------------------------------------------------------------------------
# Include resource modules here.  Later, when we have the option of XS
# versions, we'll adapt this to include them if they're available.

use POE::Resources;

###############################################################################
# Helpers.

### Resolve $whatever into a session reference, trying every method we
### can until something succeeds.

sub _resolve_session {
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

sub _test_if_kernel_is_idle {
  my $self = shift;

  if (TRACE_REFCNT) {
    _warn(
      "<rc> ,----- Kernel Activity -----\n",
      "<rc> | Events : ", $kr_queue->get_item_count(), "\n",
      "<rc> | Files  : ", $self->_data_handle_count(), "\n",
      "<rc> | Extra  : ", $self->_data_extref_count(), "\n",
      "<rc> | Procs  : $kr_child_procs\n",
      "<rc> `---------------------------\n",
      "<rc> ..."
     );
  }

  unless ( $kr_queue->get_item_count() > IDLE_QUEUE_SIZE or
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

### Explain why a session could not be resolved.

sub _explain_resolve_failure {
  my ($self, $whatever) = @_;
  local $Carp::CarpLevel = 2;

  if (ASSERT_DATA) {
    _trap "<dt> Cannot resolve ``$whatever'' into a session reference";
  }

  $! = ESRCH;
  TRACE_RETVALS  and _carp    "<rv> session not resolved: $!";
  ASSERT_RETVALS and _confess "<rv> session not resolved: $!";
}

### Explain why a function is returning unsuccessfully.

sub _explain_return {
  my ($self, $message) = @_;
  local $Carp::CarpLevel = 2;

  ASSERT_RETVALS and _confess "<rv> $message";
  TRACE_RETVALS  and _carp    "<rv> $message";
}

### Explain how the user made a mistake calling a function.

sub _explain_usage {
  my ($self, $message) = @_;
  local $Carp::CarpLevel = 2;

  ASSERT_USAGE   and _confess "<us> $message";
  ASSERT_RETVALS and _confess "<rv> $message";
  TRACE_RETVALS  and _carp    "<rv> $message";
}

#==============================================================================
# SIGNALS
#==============================================================================

#------------------------------------------------------------------------------
# Register or remove signals.

# Public interface for adding or removing signal handlers.

sub sig {
  my ($self, $signal, $event_name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined signal in sig()" unless defined $signal;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
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

  if (ASSERT_USAGE) {
    _confess "<us> undefined destination in signal()"
      unless defined $destination;
    _confess "<us> undefined signal in signal()" unless defined $signal;
  };

  my $session = $self->_resolve_session($destination);
  unless (defined $session) {
    $self->_explain_resolve_failure($destination);
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

  if ($kr_active_event eq EN_SIGNAL) {
    _die(
      ",----- DEPRECATION ERROR -----\n",
      "| Session ", $self->_data_alias_loggable($kr_active_session), ":\n",
      "| handled a _signal event.  You must register a handler with sig().\n",
      "`-----------------------------\n",
    );
  }
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
      [ undef,               # KR_SESSIONS - loaded from POE::Resource::Sessions
        undef,               # KR_FILENOS - loaded from POE::Resource::FileHandles
        undef,               # KR_SIGNALS - loaded from POE::Resource::Signals
        undef,               # KR_ALIASES - loaded from POE::Resource::Aliases
        \$kr_active_session, # KR_ACTIVE_SESSION - should this be handled by POE::Resource::Sessions?
        $kr_queue,           # KR_QUEUE - should this be extracted into a Resource ?
        undef,               # KR_ID 
        undef,               # KR_SESSION_IDS - loaded from POE::Resource::SIDS
        undef,               # KR_SID_SEQ - loaded from POE::Resource::SIDS - is a scalar ref
      ], $type;

    POE::Resources->initialize();

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

    # Initialize subsystems.  The order is important.

    # We need events before sessions, and the kernel's session before
    # it can start polling for signals.  Statistics gathering requires
    # a polling event as well, so it goes late.
    $self->_data_ev_initialize($kr_queue);
    $self->_initialize_kernel_session();
    $self->_data_stat_initialize() if TRACE_STATISTICS;
    $self->_data_sig_initialize();

    # These other subsystems don't have strange interactions.
    $self->_data_handle_initialize($kr_queue);
  }

  # Return the global instance.
  $poe_kernel;
}

#------------------------------------------------------------------------------
# Send an event to a session right now.  Used by _disp_select to
# expedite select() events, and used by run() to deliver posted events
# from the queue.

# Dispatch an event to its session.  A lot of work goes on here.

sub _dispatch_event {
  my ( $self,
       $session, $source_session, $event, $type, $etc, $file, $line,
       $time, $seq
     ) = @_;

  if (ASSERT_EVENTS) {
    _confess "<ev> undefined dest session" unless defined $session;
    _confess "<ev> undefined source session" unless defined $source_session;
  };

  if (TRACE_EVENTS) {
    my $log_session = $session;
    $log_session =  $self->_data_alias_loggable($session)
      unless $type & ET_START;
    my $string_etc = join(" ", map { defined() ? $_ : "(undef)" } @$etc);
    _warn(
      "<ev> Dispatching event $seq ``$event'' ($string_etc) from ",
      $self->_data_alias_loggable($source_session), " to $log_session"
    );
  }

  my $local_event = $event;

  $self->_stat_profile($event) if TRACE_PROFILE;

  # Pre-dispatch processing.

  unless ($type & (ET_POST | ET_CALL)) {

    # A "select" event has just come out of the queue.  Reset its
    # actual state to its requested state before handling the event.

    if ($type & ET_SELECT) {
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

    # Preprocess signals.  This is where _signal is translated into
    # its registered handler's event name, if there is one.

    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];

      if (TRACE_SIGNALS) {
        _warn(
          "<sg> dispatching ET_SIGNAL ($signal) to ",
          $self->_data_alias_loggable($session)
        );
      }

      # Step 0: Reset per-signal structures.

      $self->_data_sig_reset_handled($signal);

      # Step 1: Propagate the signal to sessions that are watching it.

      if ($self->_data_sig_explicitly_watched($signal)) {
        my %signal_watchers = $self->_data_sig_watchers($signal);
        while (my ($session, $event) = each %signal_watchers) {
          my $session_ref = $self->_data_ses_resolve($session);

          if (TRACE_SIGNALS) {
            _warn(
              "<sg> propagating explicit signal $event ($signal) ",
              "to ", $self->_data_alias_loggable($session_ref)
            );
          }

          $self->_dispatch_event
            ( $session_ref, $self,
              $event, ET_SIGNAL_EXPLICIT, $etc,
              $file, $line, time(), -__LINE__
            );
        }
      }
    }

    # Save the name of the event we're processing.
    my $hold_active_event = $kr_active_event;
    $kr_active_event = $event;

    # Step 2: Propagate the signal to this session's children.  This
    # happens first, making the signal's traversal through the
    # parent/child tree depth first.  It ensures that signals posted
    # to the Kernel are delivered to the Kernel last.

    if ($type & (ET_SIGNAL | ET_SIGNAL_COMPATIBLE)) {
      my $signal = $etc->[0];
      foreach ($self->_data_ses_get_children($session)) {

        if (TRACE_SIGNALS) {
          _warn(
            "<sg> propagating compatible signal ($signal) to ",
            $self->_data_alias_loggable($_)
          );
        }

        $self->_dispatch_event
          ( $_, $self,
            $event, ET_SIGNAL_COMPATIBLE, $etc,
            $file, $line, time(), -__LINE__
          );

        if (TRACE_SIGNALS) {
          _warn(
            "<sg> propagated to ",
            $self->_data_alias_loggable($_)
          );
        }
      }

      # If this session already received a signal in step 1, then
      # ignore dispatching it again in this step.
      return if (
        ($type & ET_SIGNAL_COMPATIBLE) and
        $self->_data_sig_is_watched_by_session($signal, $session)
      );
    }
  }

  # The destination session doesn't exist.  This indicates sloppy
  # programming, possibly within POE::Kernel.

  unless ($self->_data_ses_exists($session)) {
    if (TRACE_EVENTS) {
      _warn(
        "<ev> discarding event $seq ``$event'' to nonexistent ",
        $self->_data_alias_loggable($session)
      );
    }
    return;
  }

  if (TRACE_EVENTS) {
    _warn(
    "<ev> dispatching event $seq ``$event'' to ",
      $self->_data_alias_loggable($session)
    );
    if ($event eq EN_SIGNAL) {
      _warn("<ev>     signal($etc->[0])");
    }
  }

  # Prepare to call the appropriate handler.  Push the current active
  # session on Perl's call stack.
  my $hold_active_session = $kr_active_session;
  $kr_active_session = $session;

  my $hold_active_event = $kr_active_event;
  $kr_active_event = $event;

  # Clear the implicit/explicit signal handler flags for this event
  # dispatch.  We'll use them afterward to carp at the user if they
  # handled something implicitly but not explicitly.

  $self->_data_sig_clear_handled_flags();

  # Dispatch the event, at long last.
  my $before;
  if (TRACE_STATISTICS) {
      $before = time();
  }
  my $return;
  if (wantarray) {
    $return =
      [ $session->_invoke_state($source_session, $event, $etc, $file, $line) ];
  }
  else {
    $return =
      $session->_invoke_state($source_session, $event, $etc, $file, $line);
  }

  if (TRACE_STATISTICS) {
      my $after = time();
      my $elapsed = $after - $before;
      if ($type & ET_MASK_USER) {
	  $self->_data_stat_add('user_seconds', $elapsed);
	  $self->_data_stat_add('user_events', 1);
      }
  }

  # Stringify the handler's return value if it belongs in the POE
  # namespace.  $return's scope exists beyond the post-dispatch
  # processing, which includes POE's garbage collection.  The scope
  # bleed was known to break determinism in surprising ways.

  if (defined $return and substr(ref($return), 0, 5) eq 'POE::') {
    $return = "$return";
  }

  # Pop the active session, now that it's not active anymore.
  $kr_active_session = $hold_active_session;

  if (TRACE_EVENTS) {
    my $string_ret = $return;
    $string_ret = "undef" unless defined $string_ret;
    _warn("<ev> event $seq ``$event'' returns ($string_ret)\n");
  }

  # Post-dispatch processing.
  #
  # If this invocation is a user event, see if the destination session
  # needs to be garbage collected.  Also check the source session if
  # it's different from the destination.
  #
  # If the invocation is a call, and the destination session is
  # different from the calling one, test it for garbage collection.
  # We avoid testing if the source and destination are the same
  # because at some point we'll hit a user event that will catch it.
  #
  # -><- We test whether the sessions exist.  They should, but we've
  # been getting double-free errors lately.  I think we should avoid
  # the double free some other way, but this is the most expedient
  # method.
  #
  # -><- It turns out that POE::NFA->stop() may have discarded
  # sessions already, so we need to do the GC test anyway.  Maybe some
  # sort of mark-and-sweep can avoid redundant tests.

  if ($type & ET_POST) {
    $self->_data_ses_collect_garbage($session)
      if $self->_data_ses_exists($session);
    $self->_data_ses_collect_garbage($source_session)
      if ( $session != $source_session and
           $self->_data_ses_exists($source_session)
         );
  }
  elsif ($type & ET_CALL and $source_session != $session) {
    $self->_data_ses_collect_garbage($session)
      if $self->_data_ses_exists($session);
  }

  # Step 3: Check for death by terminal signal.

  if ($type & (ET_SIGNAL | ET_SIGNAL_EXPLICIT | ET_SIGNAL_COMPATIBLE)) {
    $self->_data_sig_touched_session($session, $event, $return, $etc->[0]);

    if ($type & ET_SIGNAL) {
      $self->_data_sig_free_terminated_sessions();
    }
  }

  # These types of events require garbage collection afterwards, but
  # they don't need any other processing.

  elsif ($type & (ET_ALARM | ET_SELECT)) {
    $self->_data_ses_collect_garbage($session);
  }

  # Recover the event being processed.
  $kr_active_event = $hold_active_event;

  # Return what the handler did.  This is used for call().
  return @$return if wantarray;
  return $return;
}

#------------------------------------------------------------------------------
# POE's main loop!  Now with Tk and Event support!

# Do pre-run startup.  Initialize the event loop, and allocate a
# session structure to represent the Kernel.

sub _initialize_kernel_session {
  my $self = shift;

  $self->loop_initialize();

  $kr_active_session = $self;
  $self->_data_ses_allocate($self, $self->[KR_ID], undef);
}

# Do post-run cleanup.

sub finalize_kernel {
  my $self = shift;

  # Disable signal watching since there's now no place for them to go.
  foreach ($self->_data_sig_get_safe_signals()) {
    $self->loop_ignore_signal($_);
  }

  # The main loop is done, no matter which event library ran it.
  $self->loop_finalize();
  $self->_data_extref_finalize();
  $self->_data_sid_finalize();
  $self->_data_sig_finalize();
  $self->_data_alias_finalize();
  $self->_data_handle_finalize();
  $self->_data_ev_finalize();
  $self->_data_ses_finalize();
  $self->_data_stat_finalize() if TRACE_PROFILE or TRACE_STATISTICS;
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

# Stops the kernel cold.  XXX Experimental!
# No events happen as a result of this, all structures are cleaned up
# except the current session which will be cleaned up when the current
# state handler returns.
sub stop {
  # So stop() can be called as a class method.
  my $self = $poe_kernel;

  my @children = ($self);
  foreach my $session (@children) {
    push @children, $self->_data_ses_get_children($session);
  }

  # Remove the kernel itself.
  shift @children;

  # Walk backwards to avoid inconsistency errors.
  foreach my $session (reverse @children) {
    $self->_data_ses_free($session);
  }

  # So new sessions will not be child of the current defunct session.
  $kr_active_session = $self;

  undef;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  # Warn that a session never had the opportunity to run if one was
  # created but run() was never called.

  unless ($kr_run_warning & KR_RUN_CALLED) {
    _warn("POE::Kernel's run() method was never called.\n")
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

    if (TRACE_SIGNALS) {
      _warn("<sg> POE::Kernel is polling for signals at " . time())
    }

    # Reap children for as long as waitpid(2) says something
    # interesting has happened.  -><- This has a strong possibility of
    # an infinite loop.

    my $pid;
    while ($pid = waitpid(-1, WNOHANG)) {

      # waitpid(2) returned a process ID.  Emit an appropriate SIGCHLD
      # event and loop around again.

      if ((RUNNING_IN_HELL and $pid < -1) or ($pid > 0)) {
        if (RUNNING_IN_HELL or WIFEXITED($?) or WIFSIGNALED($?)) {

          if (TRACE_SIGNALS) {
            _warn("<sg> POE::Kernel detected SIGCHLD (pid=$pid; exit=$?)");
          }

          $self->_data_ev_enqueue
            ( $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'CHLD', $pid, $? ],
              __FILE__, __LINE__, time(),
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

      _trap "internal consistency error: waitpid returned $pid"
        if $pid != -1;

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

      # No child processes exist.  -><- This is different than
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

    # If waitpid() returned 0, then we have child processes.

    $kr_child_procs = !$pid;

    # The poll loop is over.  Resume slowly polling for signals.

    if (TRACE_SIGNALS) {
      _warn("<sg> POE::Kernel will poll again after a delay");
    }

    $self->_data_ev_enqueue(
      $self, $self, EN_SCPOLL, ET_SCPOLL, [ ],
      __FILE__, __LINE__, time() + 1
    ) if $self->_data_ses_count() > 1;
  }

  # A signal was posted.  Because signals propagate depth-first, this
  # _invoke_state is called last in the dispatch.  If the signal was
  # SIGIDLE, then post a SIGZOMBIE if the main queue is still idle.

  elsif ($event eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (
        $kr_queue->get_item_count() > IDLE_QUEUE_SIZE or
        $self->_data_handle_count()
      ) {
        $self->_data_ev_enqueue
          ( $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'ZOMBIE' ],
            __FILE__, __LINE__, time(),
          );
      }
    }
  }

  elsif ($event eq EN_STAT) {
      $self->_data_stat_tick();
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
    $self->_data_stat_initialize() if TRACE_STATISTICS;
    $self->_data_sig_initialize();
  }

  if (ASSERT_DATA) {
    if ($self->_data_ses_exists($session)) {
      _trap(
        "<ss> ", $self->_data_alias_loggable($session), " already exists\a"
      );
    }
  }

  # Register that a session was created.
  $kr_run_warning |= KR_RUN_SESSION;

  # Allocate the session's data structure.  This must be done before
  # we dispatch anything regarding the new session.
  my $new_sid = $self->_data_sid_allocate();
  $self->_data_ses_allocate($session, $new_sid, $kr_active_session);

  # Tell the new session that it has been created.  Catch the _start
  # state's return value so we can pass it to the parent with the
  # _child create.
  my $return = $self->_dispatch_event(
    $session, $kr_active_session,
    EN_START, ET_START, \@args,
    __FILE__, __LINE__, time(), -__LINE__
  );

  # If the child has not detached itself---that is, if its parent is
  # the currently active session---then notify the parent with a
  # _child create event.  Otherwise skip it, since we'd otherwise
  # throw a create without a lose.
  $self->_dispatch_event(
    $self->_data_ses_get_parent($session), $self,
    EN_CHILD, ET_CHILD, [ CHILD_CREATE, $session, $return ],
    __FILE__, __LINE__, time(), -__LINE__
  );

  # Enqueue a delayed garbage-collection event so the session has time
  # to do its thing before it goes.
  $self->_data_ev_enqueue(
    $session, $session, EN_GC, ET_GC, [],
    __FILE__, __LINE__, time(),
  );
}

# Detach a session from its parent.  This breaks the parent/child
# relationship between the current session and its parent.  Basically,
# the current session is given to the Kernel session.  Unlike with
# _stop, the current session's children follow their parent.
#
# TODO - Calling detach_myself() from _start means the parent receives
# a "_child lose" event without ever seeing "_child create".

sub detach_myself {
  my $self = shift;

  # Can't detach from the kernel.
  if ($self->_data_ses_get_parent($kr_active_session) == $self) {
    $! = EPERM;
    return;
  }

  my $old_parent = $self->_data_ses_get_parent($kr_active_session);

  # Tell the old parent session that the child is departing.
  $self->_dispatch_event(
    $old_parent, $self,
    EN_CHILD, ET_CHILD, [ CHILD_LOSE, $kr_active_session ],
    (caller)[1,2], time(), -__LINE__
  );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the current session that its parentage is changing.
  $self->_dispatch_event(
    $kr_active_session, $self,
    EN_PARENT, ET_PARENT, [ $old_parent, $self ],
    (caller)[1,2], time(), -__LINE__
  );

  $self->_data_ses_move_child($kr_active_session, $self);

  # Test the old parent for garbage.
  $self->_data_ses_collect_garbage($old_parent);

  # Success!
  return 1;
}

# Detach a child from this, the parent.  The session being detached
# must be a child of the current session.

sub detach_child {
  my ($self, $child) = @_;

  my $child_session = $self->_resolve_session($child);
  unless (defined $child_session) {
    $self->_explain_resolve_failure($child);
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
  $self->_dispatch_event(
    $kr_active_session, $self,
    EN_CHILD, ET_CHILD, [ CHILD_LOSE, $child_session ],
    (caller)[1,2], time(), -__LINE__
  );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the child session that its parentage is changing.
  $self->_dispatch_event(
    $child_session, $self,
    EN_PARENT, ET_PARENT, [ $kr_active_session, $self ],
    (caller)[1,2], time(), -__LINE__
  );

  $self->_data_ses_move_child($child_session, $self);

  # Test the old parent for garbage.
  $self->_data_ses_collect_garbage($kr_active_session);

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

  if (ASSERT_USAGE) {
    _confess "<us> destination is undefined in post()"
      unless defined $destination;
    _confess "<us> event is undefined in post()" unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by posting it"
    ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = $self->_resolve_session($destination);
  unless (defined $session) {
    $self->_explain_resolve_failure($destination);
    return;
  }

  # Enqueue the event for "now", which simulates FIFO in our
  # time-ordered queue.

  $self->_data_ev_enqueue
    ( $session, $kr_active_session, $event_name, ET_POST, \@etc,
      (caller)[1,2], time(),
    );
  return 1;
}

#------------------------------------------------------------------------------
# Post an event to the queue for the current session.

sub yield {
  my ($self, $event_name, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> event name is undefined in yield()"
      unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by yielding it"
    ) if exists $poes_own_events{$event_name};
  };

  $self->_data_ev_enqueue
    ( $kr_active_session, $kr_active_session, $event_name, ET_POST, \@etc,
      (caller)[1,2], time(),
    );

  undef;
}

#------------------------------------------------------------------------------
# Call an event handler directly.

sub call {
  my ($self, $destination, $event_name, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> destination is undefined in call()"
      unless defined $destination;
    _confess "<us> event is undefined in call()" unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by calling it"
    ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = $self->_resolve_session($destination);
  unless (defined $session) {
    $self->_explain_resolve_failure($destination);
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

  my $return_value;
  if (wantarray) {
    $return_value = [
      $self->_dispatch_event(
        $session, $kr_active_session,
        $event_name, ET_CALL, \@etc,
        (caller)[1,2], time(), -__LINE__
      )
    ];
  }
  else {
    $return_value = $self->_dispatch_event(
      $session, $kr_active_session,
      $event_name, ET_CALL, \@etc,
      (caller)[1,2], time(), -__LINE__
    );
  }

  $! = 0;
  return @$return_value if wantarray;
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

  if (ASSERT_USAGE) {
    _confess "<us> event name is undefined in alarm()"
      unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting an alarm for it"
    ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name) {
    $self->_explain_return("invalid parameter to alarm() call");
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

  if (ASSERT_USAGE) {
    _confess "<us> undefined event name in alarm_add()"
      unless defined $event_name;
    _confess "<us> undefined time in alarm_add()" unless defined $time;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by adding an alarm for it"
    ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name and defined $time) {
    $self->_explain_return("invalid parameter to alarm_add() call");
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

  if (ASSERT_USAGE) {
    _confess "<us> undefined event name in delay()" unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a delay for it"
    ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name) {
    $self->_explain_return("invalid parameter to delay() call");
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

  if (ASSERT_USAGE) {
    _confess "<us> undefined event name in delay_add()"
      unless defined $event_name;
    _confess "<us> undefined time in delay_add()" unless defined $delay;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by adding a delay for it"
    ) if exists $poes_own_events{$event_name};
  };

  unless (defined $event_name and defined $delay) {
    $self->_explain_return("invalid parameter to delay_add() call");
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
    $self->_explain_usage("undefined event name in alarm_set()");
    $! = EINVAL;
    return;
  }

  unless (defined $time) {
    $self->_explain_usage("undefined time in alarm_set()");
    $! = EINVAL;
    return;
  }

  if (ASSERT_USAGE) {
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
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
    $self->_explain_usage("undefined alarm id in alarm_remove()");
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
# re-adds it somewhere else.  In reality, adjust_priority() is
# optimized for this sort of thing.

sub alarm_adjust {
  my ($self, $alarm_id, $delta) = @_;

  unless (defined $alarm_id) {
    $self->_explain_usage("undefined alarm id in alarm_adjust()");
    $! = EINVAL;
    return;
  }

  unless (defined $delta) {
    $self->_explain_usage("undefined alarm delta in alarm_adjust()");
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
    $self->_explain_usage("undefined event name in delay_set()");
    $! = EINVAL;
    return;
  }

  if (ASSERT_USAGE) {
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a delay for it"
    ) if exists $poes_own_events{$event_name};
  }

  unless (defined $seconds) {
    $self->_explain_usage("undefined seconds in delay_set()");
    $! = EINVAL;
    return;
  }

  return $self->_data_ev_enqueue
    ( $kr_active_session, $kr_active_session, $event_name, ET_ALARM, [ @etc ],
      (caller)[1,2], time() + $seconds,
    );
}

# Move a delay to a new offset from time().  As with alarm_adjust(),
# this is optimized internally for this sort of activity.

sub delay_adjust {
  my ($self, $alarm_id, $seconds) = @_;

  unless (defined $alarm_id) {
    $self->_explain_usage("undefined delay id in delay_adjust()");
    $! = EINVAL;
    return;
  }

  unless (defined $seconds) {
    $self->_explain_usage("undefined delay seconds in delay_abjust()");
    $! = EINVAL;
    return;
  }

  my $my_delay = sub {
    $_[0]->[EV_SESSION] == $kr_active_session;
  };
  return $kr_queue->set_priority($alarm_id, $my_delay, time() + $seconds);
}

# Remove all alarms for the current session.

sub alarm_remove_all {
  my $self = shift;

  # This should never happen, actually.
  _trap "unknown session in alarm_remove_all call"
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
    _confess "<us> undefined filehandle in select()" unless defined $handle;
    _confess "<us> invalid filehandle in select()"
      unless defined fileno($handle);
    foreach ($event_r, $event_w, $event_e) {
      next unless defined $_;
      _carp(
        "<us> The '$_' event is one of POE's own.  Its " .
        "effect cannot be achieved by setting a file watcher to it"
      ) if exists($poes_own_events{$_});
    }
  }

  $self->_internal_select($kr_active_session, $handle, $event_r, MODE_RD);
  $self->_internal_select($kr_active_session, $handle, $event_w, MODE_WR);
  $self->_internal_select($kr_active_session, $handle, $event_e, MODE_EX);
  return 0;
}

# Only manipulate the read select.
sub select_read {
  my ($self, $handle, $event_name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_read()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_read()"
      unless defined fileno($handle);
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a file watcher to it"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, MODE_RD);
  return 0;
}

# Only manipulate the write select.
sub select_write {
  my ($self, $handle, $event_name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_write()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_write()"
      unless defined fileno($handle);
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a file watcher to it"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, MODE_WR);
  return 0;
}

# Only manipulate the expedite select.
sub select_expedite {
  my ($self, $handle, $event_name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_expedite()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_expedite()"
      unless defined fileno($handle);
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a file watcher to it"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select($kr_active_session, $handle, $event_name, MODE_EX);
  return 0;
}

# Turn off a handle's write mode bit without doing
# garbage-collection things.
sub select_pause_write {
  my ($self, $handle) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_pause_write()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_pause_write()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, MODE_WR);

  $self->_data_handle_pause($handle, MODE_WR);

  return 1;
}

# Turn on a handle's write mode bit without doing garbage-collection
# things.
sub select_resume_write {
  my ($self, $handle) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_resume_write()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_resume_write()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, MODE_WR);

  $self->_data_handle_resume($handle, MODE_WR);

  return 1;
}

# Turn off a handle's read mode bit without doing garbage-collection
# things.
sub select_pause_read {
  my ($self, $handle) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_pause_read()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_pause_read()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, MODE_RD);

  $self->_data_handle_pause($handle, MODE_RD);

  return 1;
}

# Turn on a handle's read mode bit without doing garbage-collection
# things.
sub select_resume_read {
  my ($self, $handle) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined filehandle in select_resume_read()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_resume_read()"
      unless defined fileno($handle);
  };

  return 0 unless $self->_data_handle_is_good($handle, MODE_RD);

  $self->_data_handle_resume($handle, MODE_RD);

  return 1;
}

#==============================================================================
# Aliases: These functions expose the internal alias accessors with
# extra fun parameter/return value checking.
#==============================================================================

### Set an alias in the current session.

sub alias_set {
  my ($self, $name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined alias in alias_set()" unless defined $name;
  };

  # Don't overwrite another session's alias.
  my $existing_session = $self->_data_alias_resolve($name);
  if (defined $existing_session) {
    if ($existing_session != $kr_active_session) {
      $self->_explain_usage("alias '$name' is in use by another session");
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

  if (ASSERT_USAGE) {
    _confess "<us> undefined alias in alias_remove()" unless defined $name;
  };

  my $existing_session = $self->_data_alias_resolve($name);

  unless (defined $existing_session) {
    $self->_explain_usage("alias does not exist");
    return ESRCH;
  }

  if ($existing_session != $kr_active_session) {
    $self->_explain_usage("alias does not belong to current session");
    return EPERM;
  }

  $self->_data_alias_remove($kr_active_session, $name);
  return 0;
}

### Resolve an alias into a session.

sub alias_resolve {
  my ($self, $name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined alias in alias_resolve()" unless defined $name;
  };

  my $session = $self->_resolve_session($name);
  unless (defined $session) {
    $self->_explain_resolve_failure($name);
    return;
  }

  $session;
}

### List the aliases for a given session.

sub alias_list {
  my ($self, $search_session) = @_;
  my $session =
    $self->_resolve_session($search_session || $kr_active_session);

  unless (defined $session) {
    $self->_explain_resolve_failure($search_session);
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
# moot now that _resolve_session does it too.  This explicit call will
# be faster, though, so it's kept for things that can benefit from it.

sub ID_id_to_session {
  my ($self, $id) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined ID in ID_id_to_session()" unless defined $id;
  };

  my $session = $self->_data_sid_resolve($id);
  return $session if defined $session;

  $self->_explain_return("ID does not exist");
  $! = ESRCH;
  return;
}

# Resolve a session reference to its corresponding ID.

sub ID_session_to_id {
  my ($self, $session) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined session in ID_session_to_id()"
      unless defined $session;
  };

  my $id = $self->_data_ses_resolve_to_id($session);
  if (defined $id) {
    $! = 0;
    return $id;
  }

  $self->_explain_return("session ($session) does not exist");
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

  if (ASSERT_USAGE) {
    _confess "<us> undefined session ID in refcount_increment()"
      unless defined $session_id;
    _confess "<us> undefined reference count tag in refcount_increment()"
      unless defined $tag;
  };

  my $session = $self->ID_id_to_session($session_id);
  unless (defined $session) {
    $self->_explain_return("session id $session_id does not exist");
    $! = ESRCH;
    return;
  }

  my $refcount = $self->_data_extref_inc($session, $tag);
  # -><- trace it here
  return $refcount;
}

sub refcount_decrement {
  my ($self, $session_id, $tag) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined session ID in refcount_decrement()"
      unless defined $session_id;
    _confess "<us> undefined reference count tag in refcount_decrement()"
      unless defined $tag;
  };

  my $session = $self->ID_id_to_session($session_id);
  unless (defined $session) {
    $self->_explain_return("session id $session_id does not exist");
    $! = ESRCH;
    return;
  }

  my $refcount = $self->_data_extref_dec($session, $tag);
  $self->_data_ses_collect_garbage($session);

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

  if (ASSERT_USAGE) {
    _confess "<us> undefined event name in state()" unless defined $event;
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

  $self->_explain_return("session ($kr_active_session) does not exist");
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

  # Refresh an existing delay to a number of seconds in the future.
  $kernel->delay_adjust( $delay_id, $number_of_seconds_hence );

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

=item run_one_timeslice

run_one_timeslice() checks for new events, which are enqueued, then
dispatches any events that were due at the time it was called.  Then
it returns.

It is often used to emulate blocking behavior for procedural code.

  my $done = 0;

  sub handle_some_event {
    $done = 1;
  }

  while (not $done) {
    $kernel->run_one_timeslice();
  }

Note: The above example will "spin" if POE::Kernel is done but $done
isn't set.

=item stop

stop() forcibly stops the kernel.  The event queue is emptied, all
resources are released, and all sessions are deallocated.
POE::Kernel's run() method returns as if everything ended normally,
which is a lie.

B<This function has a couple serious caveats.  Use it with caution.>

The session running when stop() is called will not fully destruct
until it returns.  If you think about it, there's at least a reference
to the session in its call stack, plus POE::Kernel is holding onto at
least one reference so it can invoke the session.

Sessions are not notified about their destruction.  If anything relies
on _stop being delivered, it will break and/or leak memory.

stop() has been added as an B<experimental> function to support
forking child kernels with POE::Wheel::Run.  We may remove it without
notice if it becomes really icky.  If you have good uses for it,
please mention them on POE's mailing list.

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

ESRCH: The SESSION did not exist at the time of the post() call.

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

ESRCH: The SESSION did not exist at the time call() was called.

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

If the use of Time::HiRes is not desired, for whatever reason, it can
be disabled like so:

    sub POE::Kernel::USE_TIME_HIRES () { 0 }
    use POE;

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

=item delay_adjust DELAY_ID, SECONDS

delay_adjust adjusts an existing delay to be a number of seconds in
the future.  It is useful for refreshing watchdog timers, for
instance.

  # Refresh a delay for 10 seconds into the future.
  $new_time = $kernel->delay_adjust( $delay_id, 10 );

On failure, it returns false and sets $! to a reason for the failure.
That may be EINVAL if the delay ID or the seconds are bad values.  It
could also be ESRCH if the delay doesn't exist (perhaps it already was
dispatched).  $! may also contain EPERM if the delay doesn't belong to
the session trying to adjust it.

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

ESRCH: The Kernel's dictionary does not include the ALIAS being
removed.

EPERM: ALIAS belongs to some other session, and the current one does
not have the authority to clear it.

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

ESRCH: The Kernel's dictionary does not include ALIAS.

These functions work directly with session IDs.  They are faster than
alias_resolve() in the specific cases where they're useful.

=item ID_id_to_session SESSION_ID

ID_id_to_session() returns a session reference for a given numeric
session ID.

  $session_reference = ID_id_to_session( $session_id );

It returns undef if a lookup fails, and it sets $! to explain why the
lookup failed:

ESRCH: The session ID does not refer to a running session.

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

ESRCH: The session reference does not describe a session which is
currently running.

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

ESRCH: The Kernel doesn't recognize the currently active session.
This happens when state() is called when no session is active.

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

ESRCH: There is no session SESSION_ID currently active.

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
library.  When using Tk with POE, POE supplies an already-created
$poe_main_window variable to use for your main window.  Calling Tk's
MainWindow->new() often has an undesired outcome.

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

=item ASSERT_DATA

ASSERT_DATA enables a variety of runtime integrity checks within
POE::Kernel and its event loop bridges.  This can impose a significant
runtime penalty, so it is off by default.  The test programs for POE
all enable ASSERT_DEFAULT, which includes ASSERT_DATA.

=item ASSERT_DEFAULT

ASSERT_DEFAULT is used as the default value for all the other assert
constants.  Setting it true is a quick and reliable way to ensure all
assertions are enabled.

=item ASSERT_EVENTS

ASSERT_EVENTS enables checks for dispatching events to nonexistent
sessions.

=item ASSERT_FILES

ASSERT_FILES enables some runtime checks on the file multiplexing
syscalls used to drive POE.

=item ASSERT_RETVALS

ASSERT_RETVALS causes POE::Kernel to die if a method would return an
error.  See also TRACE_RETVALS if you want a runtime warning rather
than a hard error.

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

=item TRACE_DESTROY

Enable TRACE_DESTROY to receive a dump of the contents of Session
heaps when they finally DESTROY.  It is indispensible for finding
memory leaks, which often hide in Session heaps.

=item TRACE_EVENTS

The music goes around and around, and it comes out here.  TRACE_EVENTS
enables messages that tell what happens to FIFO and alarm events: when
they're queued, dispatched, or discarded, and what their handlers
return.

=item TRACE_FILENAME

By default, trace messages go to STDERR.  If you'd like them to go
elsewhere, set TRACE_FILENAME to the file where they should go.

=item TRACE_FILES

TRACE_FILES enables or disables messages that tell how files are being
processed within POE::Kernel and the event loop bridges.

=item TRACE_STATISTICS

B<This feature is experimental.  No doubt it will change.>

TRACE_STATISTICS enables runtime gathering and reporting of various
performance metrics within a POE program.  Some statistics include how
much time is spent processing event callbacks, time spent in POE's
dispatcher, and the time spent waiting for an event.  A report is
displayed just before run() returns, and the data can be retrieved at
any time using stat_getdata().

stat_getdata() returns a hashref of various statistics and their
values.  The statistics are calculated using a sliding window and vary
over time as a program runs.

=item TRACE_PROFILE

TRACE_PROFILE switches on event profiling.  This causes the Kernel to
keep a count of every event it dispatches.  A report of the events and
their frequencies is displayed just before run() returns, or at
any time via stat_show_profile().

=item TRACE_REFCNT

TRACE_REFCNT displays messages about reference counts for sessions,
including garbage collection tests (formerly TRACE_GARBAGE).  This is
perhaps the most useful debugging trace since it will explain why
sessions do or don't die.

=item TRACE_RETVALS

TRACE_RETVALS enables carping whenever a Kernel method is about to
return an error.  See ASSERT_RETVALS if you would like the Kernel to
be stricter than this.

=item TRACE_SESSIONS

TRACE_SESSIONS enables messages pertaining to session management.
These messages include notice when sessions are created or destroyed.
They also include parent and child relationship changes.

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
