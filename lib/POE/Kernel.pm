# $Id$

package POE::Kernel;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use POSIX qw(:fcntl_h :sys_wait_h);
use Errno qw(ESRCH EINTR ECHILD EPERM EINVAL EEXIST EAGAIN EWOULDBLOCK);
use Carp qw(carp croak confess cluck);
use Sys::Hostname qw(hostname);
use IO::Handle ();
use File::Spec ();

# People expect these to be lexical.

use vars qw($poe_kernel $poe_main_window);

#------------------------------------------------------------------------------
# A cheezy exporter to avoid using Exporter.

my $queue_class;

BEGIN {
  eval {
    require POE::XS::Queue::Array;
    POE::XS::Queue::Array->import();
    $queue_class = "POE::XS::Queue::Array";
  };
  unless ($queue_class) {
    require POE::Queue::Array;
    POE::Queue::Array->import();
    $queue_class = "POE::Queue::Array";
  }
}

sub import {
  my ($class, $args) = @_;
  my $package = caller();

  croak "POE::Kernel expects its arguments in a hash ref"
    if ($args && ref($args) ne 'HASH');

  {
    no strict 'refs';
    *{ $package . '::poe_kernel'      } = \$poe_kernel;
    *{ $package . '::poe_main_window' } = \$poe_main_window;
  }

  # Extract the import arguments we're interested in here.

  my $loop = delete $args->{loop};

  # Don't accept unknown/mistyped arguments.

  my @unknown = sort keys %$args;
  croak "Unknown POE::Kernel import arguments: @unknown" if @unknown;

  # Now do things with them.

  unless (UNIVERSAL::can('POE::Kernel', 'poe_kernel_loop')) {
    $loop =~ s/^((POE::)?Loop::)?/POE::Loop::/ if defined $loop;
    _test_loop($loop);
    # Bootstrap the kernel.  This is inherited from a time when multiple
    # kernels could be present in the same Perl process.
    POE::Kernel->new() if UNIVERSAL::can('POE::Kernel', 'poe_kernel_loop');
  }
}

#------------------------------------------------------------------------------
# Perform some optional setup.

BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';

  {
    no strict 'refs';
    if ($^O eq 'MSWin32') {
        *{ __PACKAGE__ . '::RUNNING_IN_HELL' } = sub { 1 };
    } else {
        *{ __PACKAGE__ . '::RUNNING_IN_HELL' } = sub { 0 };
    }
  }

  # POE runs better with Time::HiRes, but it also runs without it.
  { no strict 'refs';

    # Allow users to turn off Time::HiRes usage for whatever reason.
    my $time_hires_default = 1;
    $time_hires_default = $ENV{USE_TIME_HIRES} if defined $ENV{USE_TIME_HIRES};
    if (defined &USE_TIME_HIRES) {
      $time_hires_default = USE_TIME_HIRES();
    }
    else {
      *USE_TIME_HIRES = sub () { $time_hires_default };
    }
  }
}

# Second BEGIN block so that USE_TIME_HIRES is treated as a constant.
BEGIN {
  eval {
    require Time::HiRes;
    Time::HiRes->import(qw(time sleep));
  } if USE_TIME_HIRES();

  # Set up a "constant" sub that lets the user deactivate
  # automatic exception handling
  { no strict 'refs';
    unless (defined &CATCH_EXCEPTIONS) {
      *CATCH_EXCEPTIONS = sub () { 1 };
    }
  }
}

#==============================================================================
# Globals, or at least package-scoped things.  Data structures were
# moved into lexicals in 0.1201.

# A reference to the currently active session.  Used throughout the
# functions that act on the current session.
my $kr_active_session;
my $kr_active_event;

# Needs to be lexical so that POE::Resource::Events can see it
# change.  TODO - Something better?  Maybe we call a method in
# POE::Resource::Events to trigger the exception there?
use vars qw($kr_exception);

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
sub KR_RUN            () { 11 } #   \$kr_run_warning
sub KR_ACTIVE_EVENT   () { 12 } #   \$kr_active_event
sub KR_PIDS           () { 13 } #   \%kr_pids_to_events
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
sub EV_TIME       () { 7 }  #   Maintained by POE::Queue (create time)
sub EV_SEQ        () { 8 }  #   Maintained by POE::Queue (unique event ID)
                            # ]

# These are the names of POE's internal events.  They're in constants
# so we don't mistype them again.

sub EN_CHILD  () { '_child'           }
sub EN_GC     () { '_garbage_collect' }
sub EN_PARENT () { '_parent'          }
sub EN_SCPOLL () { '_sigchld_poll'    }
sub EN_SIGNAL () { '_signal'          }
sub EN_START  () { '_start'           }
sub EN_STAT   () { '_stat_tick'       }
sub EN_STOP   () { '_stop'            }

# These are POE's event classes (types).  They often shadow the event
# names themselves, but they can encompass a large group of events.
# For example, ET_ALARM describes anything enqueued as by an alarm
# call.  Types are preferred over names because bitmask tests are
# faster than string equality tests.

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
sub ET_SIGCLD () { 0x1000 }  # sig_child() events.

# A mask for all events generated by/for users.
sub ET_MASK_USER () { ~(ET_GC | ET_SCPOLL | ET_STAT) }

# Temporary signal subtypes, used during signal dispatch semantics
# deprecation and reformation.

sub ET_SIGNAL_RECURSIVE () { 0x1000 }  # Explicitly requested signal.
sub ET_SIGNAL_ANY () { ET_SIGNAL | ET_SIGNAL_RECURSIVE }

# A hash of reserved names.  It's used to test whether someone is
# trying to use an internal event directly.

my %poes_own_events = (
  +EN_CHILD  => 1,
  +EN_GC     => 1,
  +EN_CHILD  => 1,
  +EN_GC     => 1,
  +EN_PARENT => 1,
  +EN_SCPOLL => 1,
  +EN_SIGNAL => 1,
  +EN_START  => 1,
  +EN_STOP   => 1,
  +EN_STAT   => 1,
);

# These are ways a child may come or go.
# TODO - It would be useful to split 'lose' into two types.  One to
# indicate that the child has stopped, and one to indicate that it was
# given away.

sub CHILD_GAIN   () { 'gain'   }  # The session was inherited from another.
sub CHILD_LOSE   () { 'lose'   }  # The session is no longer this one's child.
sub CHILD_CREATE () { 'create' }  # The session was created as a child of this.

# Argument offsets for different types of internally generated events.
# TODO Exporting (EXPORT_OK) these would let people stop depending on
# positions for them.

sub EA_SEL_HANDLE () { 0 }
sub EA_SEL_MODE   () { 1 }
sub EA_SEL_ARGS   () { 2 }

# Queues with this many events (or more) are considered to be "large",
# and different strategies are used to find events within them.

sub LARGE_QUEUE_SIZE () { 512 }

#------------------------------------------------------------------------------
# Debugging and configuration constants.

# Shorthand for defining a trace constant.
sub _define_trace {
  no strict 'refs';
  foreach my $name (@_) {
    next if defined *{"TRACE_$name"}{CODE};
    my $trace_value = &TRACE_DEFAULT;
    my $trace_name  = "TRACE_$name";
    *$trace_name = sub () { $trace_value };
  }
}

# Debugging flags for subsystems.  They're done as double evals here
# so that someone may define them before using POE::Kernel (or POE),
# and the pre-defined value will take precedence over the defaults
# here.

BEGIN {
  # Shorthand for defining an assert constant.
  sub _define_assert {
    no strict 'refs';
    foreach my $name (@_) {
      next if defined *{"ASSERT_$name"}{CODE};
      my $assert_value = &ASSERT_DEFAULT;
      my $assert_name  = "ASSERT_$name";
      *$assert_name = sub () { $assert_value };
    }
  }

  # Assimilate POE_TRACE_* and POE_ASSERT_* environment variables.
  # Environment variables override everything else.
  while (my ($var, $val) = each %ENV) {
    next unless $var =~ /^POE_((?:TRACE|ASSERT)_[A-Z_]+)$/;
    my $const = $1;

    # Copy so we don't hurt our environment.  Make sure strings are
    # wrapped in quotes.
    my $value = $val;
    $value =~ tr['"][]d;
    $value = qq($value) if $value =~ /\D/;

    no strict 'refs';
    local $^W = 0;
    *$const = sub () { $value };
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

  defined &TRACE_DEFAULT or *TRACE_DEFAULT = sub () { 0 };

  _define_trace qw(
    EVENTS FILES PROFILE REFCNT RETVALS SESSIONS SIGNALS STATISTICS
  );

  # See the notes for TRACE_DEFAULT, except read ASSERT and assert
  # where you see TRACE and trace.

  defined &ASSERT_DEFAULT or *ASSERT_DEFAULT = sub () { 0 };

  _define_assert qw(DATA EVENTS FILES RETVALS USAGE);
}

# An "idle" POE::Kernel may still have events enqueued.  These events
# regulate polling for signals, profiling, and perhaps other aspecs of
# POE::Kernel's internal workings.
#
# XXX - There must be a better mechanism.
#
my $idle_queue_size = TRACE_PROFILE ? 1 : 0;

sub _idle_queue_grow   { $idle_queue_size++; }
sub _idle_queue_shrink { $idle_queue_size--; }
sub _idle_queue_size   { $idle_queue_size;   }

#------------------------------------------------------------------------------
# Helpers to carp, croak, confess, cluck, warn and die with whatever
# trace file we're using today.  _trap is reserved for internal
# errors.

{
  # This block abstracts away a particular piece of voodoo, since we're about
  # to call it many times. This is all a big closure around the following two
  # variables, allowing us to swap out and replace handlers without the need
  # for mucking up the namespace or the kernel itself.
  my ($orig_warn_handler, $orig_die_handler);

  # _trap_death replaces the current __WARN__ and __DIE__ handlers
  # with our own.  We keep the defaults around so we can put them back
  # when we're done.  Specifically this is necessary, it seems, for
  # older perls that don't respect the C<local *STDERR = *TRACE_FILE>.
  #
  # TODO - The __DIE__ handler generates a double message if
  # TRACE_FILE is STDERR and the die isn't caught by eval.  That's
  # messy and needs to go.
  sub _trap_death {
    $orig_warn_handler = $SIG{__WARN__};
    $orig_die_handler = $SIG{__DIE__};

    $SIG{__WARN__} = sub { print TRACE_FILE $_[0] };
    $SIG{__DIE__} = sub { print TRACE_FILE $_[0]; die $_[0]; };
  }

  # _release_death puts the original __WARN__ and __DIE__ handlers back in
  # place. Hopefully this is zero-impact camping. The hope is that we can
  # do our trace magic without impacting anyone else.
  sub _release_death {
    $SIG{__WARN__} = $orig_warn_handler;
    $SIG{__DIE__} = $orig_die_handler;
  }
}


sub _trap {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;

  _trap_death();
  confess(
    "Please mail the following information to bug-POE\@rt.cpan.org:\n@_"
  );
  _release_death();
}

sub _croak {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;

  _trap_death();
  croak @_;
  _release_death();
}

sub _confess {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;

  _trap_death();
  confess @_;
  _release_death();
}

sub _cluck {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;

  _trap_death();
  cluck @_;
  _release_death();
}

sub _carp {
  local $Carp::CarpLevel = $Carp::CarpLevel + 1;
  local *STDERR = *TRACE_FILE;

  _trap_death();
  carp @_;
  _release_death();
}

sub _warn {
  my ($package, $file, $line) = caller();
  my $message = join("", @_);
  $message .= " at $file line $line\n" unless $message =~ /\n$/;

  _trap_death();
  warn $message;
  _release_death();
}

sub _die {
  my ($package, $file, $line) = caller();
  my $message = join("", @_);
  $message .= " at $file line $line\n" unless $message =~ /\n$/;
  local *STDERR = *TRACE_FILE;

  _trap_death();
  die $message;
  _release_death();
}

#------------------------------------------------------------------------------
# Adapt POE::Kernel's personality to whichever event loop is present.

sub _find_loop {
  my ($mod) = @_;

  foreach my $dir (@INC) {
    return 1 if (-r "$dir/$mod");
  }
  return 0;
}

sub _load_loop {
  my $loop = shift;

  *poe_kernel_loop = sub { return "$loop" };

  # Modules can die with "not really dying" if they've loaded
  # something else.  This exception prevents the rest of the
  # originally used module from being parsed, so the module it's
  # handed off to takes over.
  eval "require $loop";
  if ($@ and $@ !~ /not really dying/) {
    die(
      "*\n",
      "* POE can't use $loop:\n",
      "* $@\n",
      "*\n",
    );
  }
}

sub _test_loop {
  my $used_first = shift;
  local $SIG{__DIE__} = "DEFAULT";

  # First see if someone wants to load a POE::Loop or XS version
  # explicitly.
  if (defined $used_first) {
    _load_loop($used_first);
    return;
  }

  foreach my $file (keys %INC) {
    next if (substr ($file, -3) ne '.pm');
    my @split_dirs = File::Spec->splitdir($file);

    # Create a module name by replacing the path separators with
    # underscores and removing ".pm"
    my $module = join("_", @split_dirs);
    substr($module, -3) = "";

    # Skip the module name if it isn't legal.
    next if $module =~ /[^\w\.]/;

    # Try for the XS version first.  If it fails, try the plain
    # version.  If that fails, we're up a creek.
    $module = "POE/XS/Loop/$module.pm";
    unless (_find_loop($module)) {
      $module =~ s|XS/||;
      next unless (_find_loop($module));
    }

    if (defined $used_first and $used_first ne $module) {
      die(
        "*\n",
        "* POE can't use multiple event loops at once.\n",
        "* You used $used_first and $module.\n",
        "* Specify the loop you want as an argument to POE\n",
        "*  use POE qw(Loop::Select);\n",
        "* or;\n",
        "*  use POE::Kernel { loop => 'Select' };\n",
        "*\n",
      );
    }

    $used_first = $module;
  }

  # No loop found.  Default to our internal select() loop.
  unless (defined $used_first) {
    $used_first = "POE/XS/Loop/Select.pm";
    unless (_find_loop($used_first)) {
      $used_first =~ s/XS\///;
    }
  }

  substr($used_first, -3) = "";
  $used_first =~ s|/|::|g;
  _load_loop($used_first);
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
      "<rc> | Procs  : ", $self->_data_sig_child_procs(), "\n",
      "<rc> `---------------------------\n",
      "<rc> ..."
     );
  }

  unless (
    $kr_queue->get_item_count() > $idle_queue_size or
    $self->_data_handle_count() or
    $self->_data_extref_count() or
    $self->_data_sig_child_procs()
  ) {
    $self->_data_ev_enqueue(
      $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'IDLE' ],
      __FILE__, __LINE__, undef, time(),
    ) if $self->_data_ses_count();
  }
}

### Explain why a session could not be resolved.

sub _explain_resolve_failure {
  my ($self, $whatever, $nonfatal) = @_;
  local $Carp::CarpLevel = 2;

  if (ASSERT_DATA and !$nonfatal) {
    _trap "<dt> Cannot resolve ``$whatever'' into a session reference";
  }

  $! = ESRCH;
  TRACE_RETVALS  and _carp "<rv> session not resolved: $!";
  ASSERT_RETVALS and _carp "<rv> session not resolved: $!";
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
    _confess "<us> must call sig() from a running session"
      if $kr_active_session == $self;
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
# TODO - Like post(), signal() should return 

sub signal {
  my ($self, $dest_session, $signal, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> undefined destination in signal()"
      unless defined $dest_session;
    _confess "<us> undefined signal in signal()" unless defined $signal;
  };

  my $session = $self->_resolve_session($dest_session);
  unless (defined $session) {
    $self->_explain_resolve_failure($dest_session);
    return;
  }

  $self->_data_ev_enqueue(
    $session, $kr_active_session,
    EN_SIGNAL, ET_SIGNAL, [ $signal, @etc ],
    (caller)[1,2], $kr_active_event, time(),
  );
  return 1;
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

# Handle child PIDs being reaped.  Added 2006-09-15.

sub sig_child {
  my ($self, $pid, $event_name) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call sig_chld() from a running session"
      if $kr_active_session == $self;
    _confess "<us> undefined process ID in sig_chld()" unless defined $pid;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved assigning it to a signal"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  if (defined $event_name) {
    $self->_data_sig_pid_watch($kr_active_session, $pid, $event_name);
  }
  elsif ($self->_data_sig_pids_is_ses_watching($kr_active_session, $pid)) {
    $self->_data_sig_pid_ignore($kr_active_session, $pid);
  }
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
    $kr_queue = $queue_class->new();

    # TODO - Should KR_ACTIVE_SESSIONS and KR_ACTIVE_EVENT be handled
    # by POE::Resource::Sessions?
    # TODO - Should the subsystems be split off into separate real
    # objects, such as KR_QUEUE is?

    my $self = $poe_kernel = bless [
      undef,               # KR_SESSIONS - from POE::Resource::Sessions
      undef,               # KR_FILENOS - from POE::Resource::FileHandles
      undef,               # KR_SIGNALS - from POE::Resource::Signals
      undef,               # KR_ALIASES - from POE::Resource::Aliases
      \$kr_active_session, # KR_ACTIVE_SESSION
      $kr_queue,           # KR_QUEUE - reference to an object
      undef,               # KR_ID
      undef,               # KR_SESSION_IDS - from POE::Resource::SIDS
      undef,               # KR_SID_SEQ - scalar ref from POE::Resource::SIDS
      undef,               # KR_EXTRA_REFS
      undef,               # KR_SIZE
      \$kr_run_warning,    # KR_RUN
      \$kr_active_event,   # KR_ACTIVE_EVENT
    ], $type;

    POE::Resources->initialize();

    $self->_data_sid_set($self->ID(), $self);

    # Initialize subsystems.  The order is important.

    # We need events before sessions, and the kernel's session before
    # it can start polling for signals.  Statistics gathering requires
    # a polling event as well, so it goes late.
    $self->_data_ev_initialize($kr_queue);
    $self->_initialize_kernel_session();
    $self->_data_stat_initialize() if TRACE_STATISTICS;
    $self->_data_sig_initialize();
    $self->_data_magic_initialize();
    $self->_data_alias_initialize();

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
  my (
    $self,
    $session, $source_session, $event, $type, $etc,
    $file, $line, $fromstate, $time, $seq
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

      # Step 1a: Reset the handled-signal flags.

      local @POE::Kernel::kr_signaled_sessions;
      local $POE::Kernel::kr_signal_total_handled;
      local $POE::Kernel::kr_signal_type;

      $self->_data_sig_reset_handled($signal);

      my @touched_sessions = ($session);
      my $touched_index = 0;
      while ($touched_index < @touched_sessions) {
        my $next_target = $touched_sessions[$touched_index];
        push @touched_sessions, $self->_data_ses_get_children($next_target);
        $touched_index++;
      }

      # Step 2: Propagate the signal to sessions that are watching it.

      if ($self->_data_sig_explicitly_watched($signal)) {
        $touched_index = @touched_sessions;
        my %signal_watchers = $self->_data_sig_watchers($signal);
        while ($touched_index--) {
          my $target_session = $touched_sessions[$touched_index];

          $self->_data_sig_touched_session($target_session);

          my $target_event = $signal_watchers{$target_session};
          next unless defined $target_event;

          if (TRACE_SIGNALS) {
            _warn(
              "<sg> propagating explicit signal $target_event ($signal) ",
              "to ", $self->_data_alias_loggable($target_session)
            );
          }

          $self->_dispatch_event(
            $target_session, $self,
            $target_event, ET_SIGNAL_RECURSIVE, [ @$etc ],
            $file, $line, $fromstate, time(), -__LINE__
          );
        }
      }
      else {
        # TODO This is ugly repeated code.  See the block just above
        # the else.

        $touched_index = @touched_sessions;
        while ($touched_index--) {
          my $target_session = $touched_sessions[$touched_index];

          $self->_data_sig_touched_session(
            $target_session, $event, 0, $etc->[0],
          );
        }
      }

      # Step 3: Check to see if the signal was handled.

      $self->_data_sig_free_terminated_sessions();

      # Signal completely dispatched.  Thanks for flying!
      return (_data_sig_handled_status())[0];
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

  # Dispatch the event, at long last.
  my $before;
  if (TRACE_STATISTICS) {
    $before = time();
  }

  my $return;
  my $wantarray = wantarray;
  if (CATCH_EXCEPTIONS) {
    eval {
      if ($wantarray) {
        $return = [
          $session->_invoke_state(
            $source_session, $event, $etc, $file, $line, $fromstate
          )
        ];
      }
      elsif (defined $wantarray) {
        $return = $session->_invoke_state(
          $source_session, $event, $etc, $file, $line, $fromstate
        );
      }
      else {
        $session->_invoke_state(
          $source_session, $event, $etc, $file, $line, $fromstate
        );
      }
    };

    # local $@ doesn't work quite the way I expect, but there is a
    # bit of a problem if an eval{} occurs here because a signal is
    # dispatched or something.

    if (ref($@) or $@ ne '') {
      my $exception = $@;

      if(TRACE_EVENTS) {
        _warn(
          "<ev> exception occurred in $event when invoked on ",
          $self->_data_alias_loggable($session)
        );
      }

      # While it looks like we're checking the signal handler's return
      # value, we actually aren't.  _dispatch_event() for signals
      # returns whether the signal was handled.  See the return at the
      # end of "Step 3" in the signal handling procedure.
      my $handled = $self->_dispatch_event(
        $session,
        $source_session,
        EN_SIGNAL,
        ET_SIGNAL,
        [
          'DIE' => {
            source_session => $source_session,
            dest_session => $session,
            event => $event,
            file => $file,
            line => $line,
            from_state => $fromstate,
            error_str => $exception,
          },
        ],
        __FILE__,
        __LINE__,
        undef,
        time(),
        -__LINE__,
      );

      # An exception has occurred.  Set a global that we can check at
      # the uppermost level.
      unless ($handled) {
        $kr_exception = $exception;
      }
    }
  }
  else {
    if ($wantarray) {
      $return = [
        $session->_invoke_state(
          $source_session, $event, $etc, $file, $line, $fromstate
        )
      ];
    }
    elsif (defined $wantarray) {
      $return = $session->_invoke_state(
        $source_session, $event, $etc, $file, $line, $fromstate
      );
    }
    else {
      $session->_invoke_state(
        $source_session, $event, $etc, $file, $line, $fromstate
      );
    }
  }


  # Clear out the event arguments list, in case there are POE-ish
  # things in it. This allows them to destruct happily before we set
  # the current session back.
  #
  # We must preserve $_[ARG0] if the event is a signal.  It contains
  # the signal name, which is used by post-invoke processing to
  # determine future actions (such as whether to terminate the
  # session, or to promote SIGIDLE into SIGZOMBIE).
  #
  # TODO - @$etc contains @_[ARG0..$#_], which includes both watcher-
  # and user-supplied elements.  A more exciting solution might be to
  # have a table of events and their user-supplied indices, and wipe
  # them out programmatically.  splice(@$etc, $first_user{$type});
  # That would leave the watcher-supplied arguments alone.

  @$etc = ( );

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

  # Recover the event being processed.
  $kr_active_event = $hold_active_event;

  if (TRACE_EVENTS) {
    my $string_ret = $return;
    $string_ret = "undef" unless defined $string_ret;
    _warn("<ev> event $seq ``$event'' returns ($string_ret)\n");
  }

  # Bail out of post-dispatch processing if the session has been
  # stopped.  TODO This is extreme overhead.
  return unless $self->_data_ses_exists($session);

  # If this invocation is a user event, see if the destination session
  # needs to be garbage collected.  Also check the source session if
  # it's different from the destination.
  #
  # If the invocation is a call, and the destination session is
  # different from the calling one, test it for garbage collection.
  # We avoid testing if the source and destination are the same
  # because at some point we'll hit a user event that will catch it.
  #
  # TODO We test whether the sessions exist.  They should, but we've
  # been getting double-free errors lately.  I think we should avoid
  # the double free some other way, but this is the most expedient
  # method.
  #
  # TODO It turns out that POE::NFA->stop() may have discarded
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

  # These types of events require garbage collection afterwards, but
  # they don't need any other processing.

  elsif ($type & (ET_ALARM | ET_SELECT)) {
    $self->_data_ses_collect_garbage($session);
  }

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

  $kr_exception = undef;
  $kr_active_session = $self;
  $self->_data_ses_allocate($self, $self->ID(), undef);
}

# Do post-run cleanup.

sub _finalize_kernel {
  my $self = shift;

  # Disable signal watching since there's now no place for them to go.
  foreach ($self->_data_sig_get_safe_signals()) {
    $self->loop_ignore_signal($_);
  }

  # Remove the kernel session's signal watcher.
  $self->_data_sig_remove($self, "IDLE");

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
  $self->_data_magic_finalize();
}

sub run_one_timeslice {
  my $self = shift;
  return undef unless $self->_data_ses_count();
  $self->loop_do_timeslice();
  unless ($self->_data_ses_count()) {
    $self->_finalize_kernel();
    $kr_run_warning |= KR_RUN_DONE;
  }
}

sub run {
  # So run() can be called as a class method.
  POE::Kernel->new unless defined $poe_kernel;
  my $self = $poe_kernel;

  # Flag that run() was called.
  $kr_run_warning |= KR_RUN_CALLED;

  # Don't run the loop if we have no sessions
  # Loop::Event will blow up, so we're doing this sanity check
  if ( $self->_data_ses_count() == 0 ) {
    # Emit noise only if we are under debug mode
    if ( ASSERT_DATA ) {
      _warn("Not running the event loop because we have no sessions!\n");
    }
  } else {
    # All signals must be explicitly watched now.  We do it here because
    # it's too early in initialize_kernel_session.
    $self->_data_sig_add($self, "IDLE", EN_SIGNAL);

    # Run the loop!
    $self->loop_run();

    # Cleanup
    $self->_finalize_kernel();
  }

  # Clean up afterwards.
  $kr_run_warning |= KR_RUN_DONE;
}

# Stops the kernel cold.  XXX Experimental!
# No events happen as a result of this, all structures are cleaned up
# except the kernel's.  Even the current session is cleaned up, which
# may introduce inconsistencies in the current session... as
# _dispatch_event() attempts to clean up for a defunct session.

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

  # Undefined the kernel ID so it will be recalculated on the next
  # ID() call.
  $self->[KR_ID] = undef;

  return;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  # Warn that a session never had the opportunity to run if one was
  # created but run() was never called.

  unless ($kr_run_warning & KR_RUN_CALLED) {
    if ($kr_run_warning & KR_RUN_SESSION) {
      _warn(
        "Sessions were started, but POE::Kernel's run() method was never\n",
        "called to execute them.  This usually happens because an error\n",
        "occurred before POE::Kernel->run() could be called.  Please fix\n",
        "any errors above this notice, and be sure that POE::Kernel->run()\n",
        "is called.\n",
      );
    }
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
    $self->_data_sig_handle_poll_event();
  }

  # A signal was posted.  Because signals propagate depth-first, this
  # _invoke_state is called last in the dispatch.  If the signal was
  # SIGIDLE, then post a SIGZOMBIE if the main queue is still idle.

  elsif ($event eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (
        $kr_queue->get_item_count() > $idle_queue_size or
        $self->_data_handle_count()
      ) {
        $self->_data_ev_enqueue(
          $self, $self, EN_SIGNAL, ET_SIGNAL, [ 'ZOMBIE' ],
          __FILE__, __LINE__, undef, time(),
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

  my $loggable = $self->_data_alias_loggable($session);

  # Tell the new session that it has been created.  Catch the _start
  # state's return value so we can pass it to the parent with the
  # _child create.
  my $return = $self->_dispatch_event(
    $session, $kr_active_session,
    EN_START, ET_START, \@args,
    __FILE__, __LINE__, undef, time(), -__LINE__
  );
  unless($self->_data_ses_exists($session)) {
    if(TRACE_SESSIONS) {
      _warn("<ss> ", $loggable, " disappeared during ", EN_START);
    }
    return $return;
  }

  # If the child has not detached itself---that is, if its parent is
  # the currently active session---then notify the parent with a
  # _child create event.  Otherwise skip it, since we'd otherwise
  # throw a create without a lose.
  $self->_dispatch_event(
    $self->_data_ses_get_parent($session), $self,
    EN_CHILD, ET_CHILD, [ CHILD_CREATE, $session, $return ],
    __FILE__, __LINE__, undef, time(), -__LINE__
  );

  unless($self->_data_ses_exists($session)) {
    if(TRACE_SESSIONS) {
      _warn("<ss> ", $loggable, " disappeared during ", EN_CHILD, " dispatch");
    }
    return $return;
  }

  # Enqueue a delayed garbage-collection event so the session has time
  # to do its thing before it goes.
  $self->_data_ev_enqueue(
    $session, $session, EN_GC, ET_GC, [],
    __FILE__, __LINE__, undef, time(),
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

  if (ASSERT_USAGE) {
    _confess "<us> must call detach_myself() from a running session"
      if $kr_active_session == $self;
  }

  # Can't detach from the kernel.
  if ($self->_data_ses_get_parent($kr_active_session) == $self) {
    $! = EPERM;
    return;
  }

  my $old_parent = $self->_data_ses_get_parent($kr_active_session);

  # Tell the old parent session that the child is departing.
  $self->_dispatch_event(
    $old_parent, $self,
    EN_CHILD, ET_CHILD, [ CHILD_LOSE, $kr_active_session, undef ],
    (caller)[1,2], undef, time(), -__LINE__
  );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the current session that its parentage is changing.
  $self->_dispatch_event(
    $kr_active_session, $self,
    EN_PARENT, ET_PARENT, [ $old_parent, $self ],
    (caller)[1,2], undef, time(), -__LINE__
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

  if (ASSERT_USAGE) {
    _confess "<us> must call detach_child() from a running session"
      if $kr_active_session == $self;
  }

  my $child_session = $self->_resolve_session($child);
  unless (defined $child_session) {
    $self->_explain_resolve_failure($child);
    return;
  }

  # Can't detach if it belongs to the kernel.  TODO We shouldn't need
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
    EN_CHILD, ET_CHILD, [ CHILD_LOSE, $child_session, undef ],
    (caller)[1,2], undef, time(), -__LINE__
  );

  # Tell the new parent (kernel) that it's gaining a child.
  # (Actually it doesn't care, so we don't do that here, but this is
  # where the code would go if it ever does in the future.)

  # Tell the child session that its parentage is changing.
  $self->_dispatch_event(
    $child_session, $self,
    EN_PARENT, ET_PARENT, [ $kr_active_session, $self ],
    (caller)[1,2], undef, time(), -__LINE__
  );

  $self->_data_ses_move_child($child_session, $self);

  # Test the old parent for garbage.
  $self->_data_ses_collect_garbage($kr_active_session);

  # Success!
  return 1;
}

### Helpful accessors.

sub get_active_session {
  return $kr_active_session;
}

sub get_active_event {
  return $kr_active_event;
}

# FIXME - Should this exist?
sub get_event_count {
  return $kr_queue->get_item_count();
}

# FIXME - Should this exist?
sub get_next_event_time {
  return $kr_queue->get_next_priority();
}

#==============================================================================
# EVENTS
#==============================================================================

#------------------------------------------------------------------------------
# Post an event to the queue.

sub post {
  my ($self, $dest_session, $event_name, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> destination is undefined in post()"
      unless defined $dest_session;
    _confess "<us> event is undefined in post()" unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by posting it"
    ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = $self->_resolve_session($dest_session);
  unless (defined $session) {
    $self->_explain_resolve_failure($dest_session);
    return;
  }

  # Enqueue the event for "now", which simulates FIFO in our
  # time-ordered queue.

  $self->_data_ev_enqueue(
    $session, $kr_active_session, $event_name, ET_POST, \@etc,
    (caller)[1,2], $kr_active_event, time(),
  );
  return 1;
}

#------------------------------------------------------------------------------
# Post an event to the queue for the current session.

sub yield {
  my ($self, $event_name, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call yield() from a running session"
      if $kr_active_session == $self;
    _confess "<us> event name is undefined in yield()"
      unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by yielding it"
    ) if exists $poes_own_events{$event_name};
  };

  $self->_data_ev_enqueue(
    $kr_active_session, $kr_active_session, $event_name, ET_POST, \@etc,
    (caller)[1,2], $kr_active_event, time(),
  );

  undef;
}

#------------------------------------------------------------------------------
# Call an event handler directly.

sub call {
  my ($self, $dest_session, $event_name, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> destination is undefined in call()"
      unless defined $dest_session;
    _confess "<us> event is undefined in call()" unless defined $event_name;
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by calling it"
    ) if exists $poes_own_events{$event_name};
  };

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = $self->_resolve_session($dest_session);
  unless (defined $session) {
    $self->_explain_resolve_failure($dest_session);
    return;
  }

  # Dispatch the event right now, bypassing the queue altogether.
  # This tends to be a Bad Thing to Do.

  # TODO The difference between synchronous and asynchronous events
  # should be made more clear in the documentation, so that people
  # have a tendency not to abuse them.  I discovered in xws that that
  # mixing the two types makes it harder than necessary to write
  # deterministic programs, but the difficulty can be ameliorated if
  # programmers set some base rules and stick to them.

  if (wantarray) {
    my @return_value = (
      ($session == $kr_active_session)
      ? $session->_invoke_state(
        $session, $event_name, \@etc, (caller)[1,2],
        $kr_active_event
      )
      : $self->_dispatch_event(
        $session, $kr_active_session,
        $event_name, ET_CALL, \@etc,
        (caller)[1,2], $kr_active_event, time(), -__LINE__
      )
    );

    $! = 0;
    return @return_value;
  }

  if (defined wantarray) {
    my $return_value = (
      $session == $kr_active_session
      ? $session->_invoke_state(
        $session, $event_name, \@etc, (caller)[1,2],
        $kr_active_event
      )
      : $self->_dispatch_event(
        $session, $kr_active_session,
        $event_name, ET_CALL, \@etc,
        (caller)[1,2], $kr_active_event, time(), -__LINE__
      )
    );

    $! = 0;
    return $return_value;
  }

  if ($session == $kr_active_session) {
    $session->_invoke_state(
      $session, $event_name, \@etc, (caller)[1,2],
      $kr_active_event
    );
  }
  else {
    $self->_dispatch_event(
      $session, $kr_active_session,
      $event_name, ET_CALL, \@etc,
      (caller)[1,2], $kr_active_event, time(), -__LINE__
    );
  }

  $! = 0;
  return;
}

#==============================================================================
# DELAYED EVENTS
#==============================================================================

sub alarm {
  my ($self, $event_name, $time, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call alarm() from a running session"
      if $kr_active_session == $self;
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
        (caller)[1,2], $kr_active_event, $time,
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
    _confess "<us> must call alarm_add() from a running session"
      if $kr_active_session == $self;
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
      (caller)[1,2], $kr_active_event, $time,
    );

  return 0;
}

# Add a delay, which is just an alarm relative to the current time.
sub delay {
  my ($self, $event_name, $delay, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call delay() from a running session"
      if $kr_active_session == $self;
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
    _confess "<us> must call delay_add() from a running session"
      if $kr_active_session == $self;
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

  if (ASSERT_USAGE) {
    _confess "<us> must call alarm_set() from a running session"
      if $kr_active_session == $self;
  }

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
      (caller)[1,2], $kr_active_event, $time,
    );
}

# Remove an alarm by its ID.  TODO Now that alarms and events have
# been recombined, this will remove an event by its ID.  However,
# nothing returns an event ID, so nobody knows what to remove.

sub alarm_remove {
  my ($self, $alarm_id) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call alarm_remove() from a running session"
      if $kr_active_session == $self;
  }

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

  if (ASSERT_USAGE) {
    _confess "<us> must call alarm_adjust() from a running session"
      if $kr_active_session == $self;
  }

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
  # Always always always grab time() ASAP, so that the eventual
  # time we set the alarm for is as close as possible to the time
  # at which they ASKED for the delay, not when we actually set it.
  my $t = time();

  # And now continue as normal
  my ($self, $event_name, $seconds, @etc) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call delay_set() from a running session"
      if $kr_active_session == $self;
  }

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
      (caller)[1,2], $kr_active_event, $t + $seconds,
    );
}

# Move a delay to a new offset from time().  As with alarm_adjust(),
# this is optimized internally for this sort of activity.

sub delay_adjust {
  my ($self, $alarm_id, $seconds) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call delay_adjust() from a running session"
      if $kr_active_session == $self;
  }

  unless (defined $alarm_id) {
    $self->_explain_usage("undefined delay id in delay_adjust()");
    $! = EINVAL;
    return;
  }

  unless (defined $seconds) {
    $self->_explain_usage("undefined delay seconds in delay_adjust()");
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

  if (ASSERT_USAGE) {
    _confess "<us> must call alarm_remove_all() from a running session"
      if $kr_active_session == $self;
  }

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
  my ($self, $session, $handle, $event_name, $mode, $args) = @_;

  # If an event is included, then we're defining a filehandle watcher.

  if ($event_name) {
    $self->_data_handle_add($handle, $mode, $session, $event_name, $args);
  }
  else {
    $self->_data_handle_remove($handle, $mode, $session);
  }
}

# A higher-level select() that manipulates read, write and expedite
# selects together.

sub select {
  my ($self, $handle, $event_r, $event_w, $event_e, @args) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call select() from a running session"
      if $kr_active_session == $self;
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

  $self->_internal_select(
    $kr_active_session, $handle, $event_r, MODE_RD, \@args
  );
  $self->_internal_select(
    $kr_active_session, $handle, $event_w, MODE_WR, \@args
  );
  $self->_internal_select(
    $kr_active_session, $handle, $event_e, MODE_EX, \@args
  );
  return 0;
}

# Only manipulate the read select.
sub select_read {
  my ($self, $handle, $event_name, @args) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call select_read() from a running session"
      if $kr_active_session == $self;
    _confess "<us> undefined filehandle in select_read()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_read()"
      unless defined fileno($handle);
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a file watcher to it"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select(
    $kr_active_session, $handle, $event_name, MODE_RD, \@args
  );
  return 0;
}

# Only manipulate the write select.
sub select_write {
  my ($self, $handle, $event_name, @args) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call select_write() from a running session"
      if $kr_active_session == $self;
    _confess "<us> undefined filehandle in select_write()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_write()"
      unless defined fileno($handle);
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a file watcher to it"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select(
    $kr_active_session, $handle, $event_name, MODE_WR, \@args
  );
  return 0;
}

# Only manipulate the expedite select.
sub select_expedite {
  my ($self, $handle, $event_name, @args) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call select_expedite() from a running session"
      if $kr_active_session == $self;
    _confess "<us> undefined filehandle in select_expedite()"
      unless defined $handle;
    _confess "<us> invalid filehandle in select_expedite()"
      unless defined fileno($handle);
    _carp(
      "<us> The '$event_name' event is one of POE's own.  Its " .
      "effect cannot be achieved by setting a file watcher to it"
    ) if defined($event_name) and exists($poes_own_events{$event_name});
  };

  $self->_internal_select(
    $kr_active_session, $handle, $event_name, MODE_EX, \@args
  );
  return 0;
}

# Turn off a handle's write mode bit without doing
# garbage-collection things.
sub select_pause_write {
  my ($self, $handle) = @_;

  if (ASSERT_USAGE) {
    _confess "<us> must call select_pause_write() from a running session"
      if $kr_active_session == $self;
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
    _confess "<us> must call select_resume_write() from a running session"
      if $kr_active_session == $self;
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
    _confess "<us> must call select_pause_read() from a running session"
      if $kr_active_session == $self;
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
    _confess "<us> must call select_resume_read() from a running session"
      if $kr_active_session == $self;
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
    $self->_explain_resolve_failure($name, "nonfatal");
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
    $self->_explain_resolve_failure($search_session, "nonfatal");
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

# The Kernel and Session IDs are based on Philip Gwyn's code.  I hope
# he still can recognize it.

sub ID {
  my $self = shift;

  # Recalculate the kernel ID if necessary.  stop() undefines it.
  unless (defined $self->[KR_ID]) {
    my $hostname = eval { (POSIX::uname)[1] };
    $hostname = hostname() unless defined $hostname;
    $self->[KR_ID] = $hostname . '-' .  unpack('H*', pack('N*', time(), $$));
  }

  return $self->[KR_ID];
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

  my $session = $self->_data_sid_resolve($session_id);
  unless (defined $session) {
    $self->_explain_return("session id $session_id does not exist");
    $! = ESRCH;
    return;
  }

  my $refcount = $self->_data_extref_inc($session, $tag);
  # TODO trace it here
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

  my $session = $self->_data_sid_resolve($session_id);
  unless (defined $session) {
    $self->_explain_return("session id $session_id does not exist");
    $! = ESRCH;
    return;
  }

  my $refcount = $self->_data_extref_dec($session, $tag);

  # We don't need to garbage-test the decremented session if the
  # reference count is nonzero.  Likewise, we don't need to GC it if
  # it's the current session under the assumption that it will be GC
  # tested when the current event dispatch is through.

  if ( !$refcount and $kr_active_session->ID ne $session_id ) {
    $self->_data_ses_collect_garbage($session);
  }

  # TODO trace it here
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
    _confess "<us> must call state() from a running session"
      if $kr_active_session == $self;
    _confess "<us> undefined event name in state()" unless defined $event;
    _confess "<us> can't call state() outside a session" if (
      $kr_active_session == $self
    );
  };

  if (
    (ref($kr_active_session) ne '') &&
    (ref($kr_active_session) ne 'POE::Kernel')
  ) {
    $kr_active_session->_register_state($event, $state_code, $state_alias);
    return 0;
  }

  # TODO A terminal signal (such as UIDESTROY) kills a session.  The
  # Kernel deallocates the session, which cascades destruction to its
  # HEAP.  That triggers a Wheel's destruction, which calls
  # $kernel->state() to remove a state from the session.  The session,
  # though, is already gone.  If TRACE_RETVALS and/or ASSERT_RETVALS
  # is set, this causes a warning or fatal error.

  $self->_explain_return("session ($kr_active_session) does not exist");
  return ESRCH;
}

1;

__END__

=head1 NAME

POE::Kernel - an event-based application kernel in Perl

=head1 SYNOPSIS

  use POE; # auto-includes POE::Kernel and POE::Session

  POE::Session->create(
    inline_states => {
      _start => sub { $_[KERNEL]->yield("next") },
      next   => sub { $_[KERNEL]->delay(next => 1) },
    },
  );

  POE::Kernel->run();
  exit;

In the spirit of Perl, there are a lot of other ways to do it.

=head1 DESCRIPTION

POE::Kernel is the heart of POE.  It provides the lowest-level
features: non-blocking multiplexed I/O, timers, and signal watchers
are the most significant.  Everything else is built upon this
foundation.

POE::Kernel is not an event loop in itself.  For that it uses one of
several available POE::Loop interface modules.  See CPAN for modules
in the POE::Loop namespace.

=head1 USING POE

=head2 Literally Using POE

POE.pm is little more than a class loader.  It implements some magic
to cut down on the setup work.

Parameters to C<use POE> are not treated as normal imports.  Rather,
they're abbreviated modules to be included along with POE.

  use POE qw(Component::Client::TCP).

As you can see, the leading "POE::" can be omitted this way.

POE.pm also includes POE::Kernel and POE::Session by default.  These
two modules are used by nearly all POE-based programs.  So the above
example is actually the equivalent of:

  use POE;
  use POE::Kernel;
  use POE::Session;
  use POE::Component::Client::TCP;

=head2 Using POE::Kernel

POE::Kernel needs to know which event loop you want to use.  This is
supported in three different ways:

The first way is to use an event loop module before using POE::Kernel
(or POE, which loads POE::Kernel for you):

  use Tk; # or one of several others
  use POE::Kernel.

POE::Kernel scans the list of modules already loaded, and it loads an
appropriate POE::Loop adapter if it finds a known event loop.

The next way is to explicitly load the POE::Loop class you want:

  use POE qw(Loop::Gtk);

Finally POE::Kernel's C<import()> supports more programmer-friendly
configuration:

  use POE::Kernel { loop => "Gtk" };
  use POE::Session;

=head2 Anatomy of a POE-Based Application

Programs using POE work like any other.  They load required modules,
perform some setup, run some code, and eventually exit.  Halting
Problem notwithstanding.

A POE-based application loads some modules, sets up one or more
sessions, runs the code in those sessions, and eventually exists.

  use POE;
  POE::Session->create( ... map events to code here ... );
  POE::Kernel->run();
  exit;

=head2 Sessions

POE implements isolated compartments called "sessions".  Sessions play
the role of tasks or threads within POE.  POE::Kernel acts as POE's
task scheduler, doling out timeslices to each session.

Sessions cooperate to share the CPU within a process.  Each session
decides when it's appropriate to be interrupted, which removes the
need to lock data shared between them.  It also gives the programmer
more control over the relative priority of each task.  A session may
take exclusive control of a program's time, if necessary.

Every POE-based application needs at least one session.  Code cannot
run "within POE" without being a part of some session.

=head1 PUBLIC METHODS

POE::Kernel encapsulates a lot of features.  The documentation for
each set of features is grouped by purpose.

=head2 Kernel Management and Accessors

=head3 ID

ID() returns the kernel's unique identifier.  Every POE::Kernel
instance is assigned a (hopefully) unique ID at birth.

  % perl -wl -MPOE -e 'print $poe_kernel->ID'
  poerbook.local-46c89ad800000e21

=head3 run

run() runs POE::Kernel's event dispatcher.  It will not return until
all sessions have ended.  run() is a class method so a POE::Kernel
reference is not needed to start a program's execution.

  use POE;
  POE::Session->create( ... ); # one or more
  POE::Kernel->run();          # set them all running
  exit;

POE implements the Reactor pattern at its core.  Events are dispatched
to functions and methods through callbacks.  The code behind run()
waits for and dispatches events.

run() will not return until every session has ended.  This includes
sessions that were created while run() was running.

=head3 run_one_timeslice

run_one_timeslice() dispatches any events that are due to be
delivered.  These events include timers that are due, asynchronous
messages that need to be delivered, signals that require handling, and
notifications for files with pending I/O.  Do not rely too much on
event ordering.  run_one_timeslice() is defined by the underlying
event loop, and its timing may vary.

run() is implemented similar to

  run_one_timeslice() while $session_count > 0;

run_one_timeslice() can be used to keep running POE::Kernel's
dispatcher while emulating blocking behavior.  The pattern is
implemented with a flag that is set when some asynchronous event
occurs.  A loop calls run_one_timeslice() until that flag is set.  For
example:

  my $done = 0;

  sub handle_some_event {
    $done = 1;
  }

  $kernel->run_one_timeslice() while not $done;

Do be careful.  The above example will spin if POE::Kernel is done but
$done is never set.  The loop will never be done, even though there's
nothing left that will set $done.

=head3 stop

stop() causes POE::Kernel->run() to return early.  It does this by
emptying the event queue, freeing all used resources, and stopping
every active session.  stop() is not meant to be used lightly.
Proceed with caution.

Caveats:

The session that calls stop() will not be fully DESTROYed until it
returns.  Invoking an event handler in the session requires a
reference to that session, and weak references are prohibited in POE
for backward compatibility reasons, so it makes sense that the last
session won't be garbage collected right away.

Sessions are not notified about their destruction.  If anything relies
on _stop being delivered, it will break and/or leak memory.

stop() is still considered experimental.  It was added to improve
fork() support for POE::Wheel::Run.  If it proves unfixably
problematic, it will be removed without much notice.

stop() is advanced magic.  Programmers who think they need it are
invited to become familiar with its source.

TODO - Example of stop().

=head2 Asynchronous Messages (FIFO Events)

Asynchronous messages are events that are dispatched in the order in
which they were enqueued (the first one in is the first one out,
otherwise known as first-in/first-out, or FIFO order).  These methods
enqueue new messages for delivery.  The act of enqueuing a message
keeps the sender alive at least until the message is delivered.

=head3 post DESTINATION, EVENT_NAME [, PARAMETER_LIST]

post() enqueues a message to be dispatched to a particular DESTINATION
session.  The message will be handled by the code associated with
EVENT_NAME.  If a PARAMETER_LIST is included, its values will also be
passed along.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->post( $_[SESSION], "event_name", 0 );
      },
      event_name => sub {
        print "$_[ARG0]\n";
        $_[KERNEL]->post( $_[SESSION], "event_name", $_[ARG0] + 1 );
      },
    }
  );

post() returns a Boolean value indicating whether the message was
successfully enqueued.  If post() returns false, $! is set to explain
the failure:

ESRCH ("No such process") - The DESTINATION session did not exist at
the time post() was called.

=head3 yield EVENT_NAME [, PARAMETER_LIST]

yield() is a shortcut for post() where the destination session is the
same as the sender.  This example is equivalent to the one for post():

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->yield( "event_name", 0 );
      },
      event_name => sub {
        print "$_[ARG0]\n";
        $_[KERNEL]->yield( "event_name", $_[ARG0] + 1 );
      },
    }
  );

As with post(), yield() returns right away, and the enquered
EVENT_NAME is dispatched later.  This may be confusing if you're
already familiar with threading.

yield() should always succeed, so it does not return a meaningful
value.

=head2 Synchronous Messages

It is sometimes necessary for code to be invoked right away.  For
example, data (especially global data) may become stale between the
time a message is enqueued and delivered.  POE provides ways to call
message handlers right away.

=head3 call DESTINATION, EVENT_NAME [, PARAMETER_LIST]

call()'s semantics are nearly identical to post()'s.  call() invokes a
DESTINATION's handler associated with an EVENT_NAME.  An optional
PARAMETER_LIST will be passed along to the message's handler.  The
difference, however, is that the handler will be invoked immediately,
even before call() returns.

call() returns the value returned by the EVENT_NAME handler.  It can
do this because the handler is invoked before call() returns.  call()
can therefore be used as an accessor, although there are better ways
to accomplish simple accessor behavior.

  POE::Session->create(
    inline_states => {
      _start => sub {
        print "Got: ", $_[KERNEL]->call($_[SESSION], "do_now"), "\n";
      },
      do_now => sub {
        return "some value";
      }
    }
  );

The POE::Wheel classes uses call() to synchronously deliver I/O
notifications.  This avoids a host of race conditions.

call() may fail in the same way and for the same reasons as post().
On failure, $! is set to some nonzero value indicating way.  Since
call() may return undef as a matter of course, it's recommended that
$! be checked for the error condition as well as the explanation.

ESRCH ("No such process") - The DESTINATION session did not exist at
the time post() was called.

=head2 Timer Events (Delayed Messages)

It's often useful to wait for a certain time or until a certain amount
of time has passed.  POE supports this with events that are deferred
until either an absolute time ("alarms") or until a certain duration
of time has elapsed ("delays").

Timer interfaces are further divided into two groups.  One group
identifies timers by the names of their associated events.  Another
group's timer constructors return identifiers that can be used to
refer to specific timers regardless of name.  Technically, the two
are both name-based, but the "identifier-based" timers provide a
second, more specific handle to identify individual timers.

Timers may only be set up for the current session.  This design was
modeled after alarm() and SIGALRM, which only affect the current UNIX
process.  Each session has a separate namespace for timer names.
Timer methods called in one session cannot affect the timers in
another.  (As you may have noticed, quite a lot of POE's API is
designed to prevent sessions from interfering with each other.)

The best way to simulate deferred inter-session messages is to send an
immediate message that causes the destination to set a timer.  The
destination's timer then defers the action requested of it.  This way
is preferred because the time spent communicating the request between
sessions may not be trivial, especially if the sessions are separated
by a network.  The destination can determine how much time remains on
the requested timer and adjust its wait time accordingly.

=head3 Time::HiRes Use

POE::Kernel timers support subsecond accuracy, but don't expect too
much here.  Perl is not the right language for realtime programming.

Subsecond accuracy is supported through the use of select() timeouts
and other event-loop features.  For increased accuracy, POE::Kernel
uses Time::HiRes's time() internally, if it's available.

You can disable POE's use of Time::HiRes by defining a constant in the
POE::Kernel namespace.  This must be done before POE::Kernel is
loaded, so that the compiler can use it.

  BEGIN {
    package POE::Kernel;
    use constant USE_TIME_HIRES => 0;
  }
  use POE;

Or the old-fashioned "constant subroutine" method.  This doesn't need
the BEGIN{} block since subroutine definitions are done at compile
time.

  sub POE::Kernel::USE_TIME_HIRES () { 0 }
  use POE;

=head3 Name-Based Timers

Name-based timers are identified by the event names used to set them.
It is possible for different sessions to use the same timer event names,
since each session is a separate compartment with its own timer namespace.
It is possible for a session to have multiple timers for a given event,
but results may be surprising.  Be careful to use the right timer methods.

The name-based timer methods are alarm(), alarm_add(), delay(), and
delay_add().

=head4 alarm EVENT_NAME [, EPOCH_TIME [, PARAMETER_LIST] ]

alarm() clears all existing timers in the current session with the
same EVENT_NAME.  It then sets a new timer, named EVENT_NAME, that
will fire EVENT_NAME at the current session when EPOCH_TIME has been
reached.  An optional PARAMETER_LIST may be passed along to the
timer's handler.

Omitting the EPOCH_TIME and subsequent parameters causes alarm() to
clear the EVENT_NAME timers in the current session without setting a
new one.

EPOCH_TIME is the UNIX epoch time.  You know, seconds since midnight,
1970-01-01.  "Now" is whatever time() returns, either the built-in or
Time::HiRes version.

POE supports fractional seconds, but accuracy falls off steeply after
1/100 second.  Mileage will vary depending on your CPU speed and your
OS time resolution.

POE's event queue is time-ordered, so a timer due before time() will
be delivered ahead of other events but not before timers with even
earlier due times.  Therefore an alarm() with an EPOCH_TIME before
time() jumps ahead of the queue.

All timers are implemented identically internally, regardless of how
they are set.  alarm() will therefore blithely clear timers set by
other means.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->alarm( tick => time() + 1, 0 );
      },
      tick => sub {
        print "tick $_[ARG0]\n";
        $_[KERNEL]->alarm( tock => time() + 1, $_[ARG0] + 1 );
      },
      tock => sub {
        print "tock $_[ARG0]\n";
        $_[KERNEL]->alarm( tick => time() + 1, $_[ARG0] + 1 );
      },
    }
  );

alarm() returns 0 on success or a true value on failure.  Usually
EINVAL to signal an invalid parameter, such as an undefined
EVENT_NAME.

=head4 alarm_add EVENT_NAME, EPOCH_TIME [, PARAMETER_LIST]

alarm_add() is used to add a new alarm timer named EVENT_NAME without
clearing existing timers.  EPOCH_TIME is a required parameter.
Otherwise the semantics are identical to alarm().

A program may use alarm_add() without first using alarm().

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->alarm_add( tick => time() + 1.0, 1_000_000 );
        $_[KERNEL]->alarm_add( tick => time() + 1.5, 2_000_000 );
      },
      tick => sub {
        print "tick $_[ARG0]\n";
        $_[KERNEL]->alarm_add( tock => time() + 1, $_[ARG0] + 1 );
      },
      tock => sub {
        print "tock $_[ARG0]\n";
        $_[KERNEL]->alarm_add( tick => time() + 1, $_[ARG0] + 1 );
      },
    }
  );

alarm_add() returns 0 on success or EINVAL if EVENT_NAME or EPOCH_TIME
is undefined.

=head4 delay EVENT_NAME [, DURATION_SECONDS [, PARAMETER_LIST] ]

delay() clears all existing timers in the current session with the
same EVENT_NAME.  It then sets a new timer, named EVENT_NAME, that
will fire EVENT_NAME at the current session when DURATION_SECONDS have
elapsed from "now".  An optional PARAMETER_LIST may be passed along to
the timer's handler.

Omitting the DURATION_SECONDS and subsequent parameters causes delay()
to clear the EVENT_NAME timers in the current session without setting
a new one.

DURATION_SECONDS may be or include fractional seconds.  As with all of
POE's timers, accuracy falls off steeply after 1/100 second.  Mileage
will vary depending on your CPU speed and your OS time resolution.

POE's event queue is time-ordered, so a timer due before time() will
be delivered ahead of other events but not before timers with even
earlier due times.  Therefore a delay () with a zero or negative
DURATION_SECONDS jumps ahead of the queue.

delay() may be considered a shorthand form of alarm(), but there are
subtle differences in timing issues.  This code is roughly equivalent
to the alarm() example.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->delay( tick => 1, 0 );
      },
      tick => sub {
        print "tick $_[ARG0]\n";
        $_[KERNEL]->delay( tock => 1, $_[ARG0] + 1 );
      },
      tock => sub {
        print "tock $_[ARG0]\n";
        $_[KERNEL]->delay( tick => 1, $_[ARG0] + 1 );
      },
    }
  );

delay() returns 0 on success or a reason for failure: EINVAL if
EVENT_NAME is undefined.

=head4 delay_add EVENT_NAME, DURATION_SECONDS [, PARAMETER_LIST]

delay_add() is used to add a new delay timer named EVENT_NAME without
clearing existing timers.  DURATION_SECONDS is a required parameter.
Otherwise the semantics are identical to delay().

A program may use delay_add() without first using delay().

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->delay_add( tick => 1.0, 1_000_000 );
        $_[KERNEL]->delay_add( tick => 1.5, 2_000_000 );
      },
      tick => sub {
        print "tick $_[ARG0]\n";
        $_[KERNEL]->delay_add( tock => 1, $_[ARG0] + 1 );
      },
      tock => sub {
        print "tock $_[ARG0]\n";
        $_[KERNEL]->delay_add( tick => 1, $_[ARG0] + 1 );
      },
    }
  );

delay_add() returns 0 on success or EINVAL if EVENT_NAME or EPOCH_TIME
is undefined.

=head3 Identifier-Based Timers

A second way to manage timers is through identifiers.  Setting an
alarm or delay with the "identifier" methods allows a program to
manipulate several timers with the same name in the same session.  As
covered in alarm() and delay() however, it's possible to mix named and
identified timer calls, but the consequences may not always be
expected.

=head4 alarm_set EVENT_NAME, EPOCH_TIME [, PARAMETER_LIST]

alarm_set() sets an alarm, returning a unique identifier that can be
used to adjust or remove the alarm later.  Unlike alarm(), it does not
first clear existing timers with the same EVENT_NAME.  Otherwise the
semantics are identical to alarm().

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[HEAP]{alarm_id} = $_[KERNEL]->alarm_set(
          party => time() + 1999
        );
        $_[KERNEL]->delay(raid => 1);
      },
      raid => sub {
        $_[KERNEL]->alarm_remove( delete $_[HEAP]{alarm_id} );
      },
    }
  );

alarm_set() returns false if it fails and sets $! with the
explanation.  $! will be EINVAL if EVENT_NAME or TIME is undefined.

=head4 alarm_adjust ALARM_ID, DELTA_SECONDS

alarm_adjust() adjusts an existing timer's due time by DELTA_SECONDS,
which may be positive or negative.  It may even be zero, but that's
not as useful.  On success, it returns the timer's new due time since
the start of the UNIX epoch.

It's possible to alarm_adjust() timers created by delay_set() as well
as alarm_set().

This example moves an alarm's due time ten seconds earlier.

  use POSIX qw(strftime);

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[HEAP]{alarm_id} = $_[KERNEL]->alarm_set(
          party => time() + 1999
        );
        $_[KERNEL]->delay(postpone => 1);
      },
      postpone => sub {
        my $new_time = $_[KERNEL]->alarm_adjust(
          $_[HEAP]{alarm_id}, 10
        );
        print(
          "Now we're gonna party like it's ",
          strftime("%F %T", gmtime($new_time)), "\n"
        );
      },
    }
  );

alarm_adjust() returns Boolean false if it fails, setting $! to the
reason why.  $! may be EINVAL if ALARM_ID or DELTA_SECONDS are
undefined.  It may be ESRCH if ALARM_ID no longer refers to a pending
timer.  $! may also contain EPERM if ALARM_ID is valid but belongs to
a different session.

=head4 alarm_remove ALARM_ID

alarm_remove() removes the alarm identified by ALARM_ID.  ALARM_ID
comes from a previous alarm_set() or delay_set() call.

Upon success, alarm_remove() returns something true based on its
context.  In a list context, it returns three things: The removed
alarm's event name, the UNIX time it was due to go off, and a
reference to the PARAMETER_LIST (if any) assigned to the timer when it
was created.  If necessary, the timer can be re-set with this
information.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[HEAP]{alarm_id} = $_[KERNEL]->alarm_set(
          party => time() + 1999
        );
        $_[KERNEL]->delay(raid => 1);
      },
      raid => sub {
        my ($name, $time, $param) = $_[KERNEL]->alarm_remove(
          $_[HEAP]{alarm_id}
        );
        print(
          "Removed alarm for event $name due at $time with @$param\n"
        );

        # Or reset it, if you'd like.  Possibly after modification.
        $_[KERNEL]->alarm_set($name, $time, @$param);
      },
    }
  );

In a scalar context, it returns a reference to a list of the three
things above.

  # Remove and reset an alarm.
  my $alarm_info = $_[KERNEL]->alarm_remove( $alarm_id );
  my $new_id = $_[KERNEL]->alarm_set(
    $alarm_info[0], $alarm_info[1], @{$alarm_info[2]}
  );

Upon failure, however, alarm_remove() returns a Boolean false value
and sets $! with the reason why the call failed:

EINVAL ("Invalid argument") indicates a problem with one or more
parameters, usually an undefined ALARM_ID.

ESRCH ("No such process") indicates that ALARM_ID did not refer to a
pending alarm.

EPERM ("Operation not permitted").  A session cannot remove an alarm
it does not own.

=head4 alarm_remove_all

alarm_remove_all() removes all the pending timers for the current
session, regardless of creation method or type.  This method takes no
arguments.  It returns information about the alarms that were removed,
either as a list of alarms or a list reference depending whether
alarm_remove_all() is called in scalar or list context.

Each removed alarm's information is identical to the format explained
in alarm_remove().

  sub some_event_handler {
    my @removed_alarms = $_[KERNEL]->alarm_remove_all();
    foreach my $alarm (@removed_alarms) {
      my ($name, $time, $param) = @$alarm;
      ...;
    }
  }

=head4 delay_set EVENT_NAME, DURATION_SECONDS [, PARAMETER_LIST]

delay_set() sets a timer for DURATION_SECONDS in the future.  The
timer will be dispatched to the code associated with EVENT_NAME in the
current session.  An optional PARAMETER_LIST will be passed through to
the handler.  It returns the same sort of things that alarm_set()
does.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->delay_set("later", 5, "hello", "world");
      },
      later => sub {
        print "@_[ARG0..#$_]\n";
      }
    }
  );

=head4 delay_adjust EVENT_NAME, SECONDS_FROM_NOW

delay_adjust() changes a timer's due time to be SECONDS_FROM_NOW.
It's useful for refreshing watchdog- or timeout-style timers.  On
success it returns the new absolute UNIX time the timer will be due.

It's possible for delay_adjust() to adjust timers created by
alarm_set() as well as delay_set().

  use POSIX qw(strftime);

  POE::Session->create(
    inline_states => {
      # Setup.
      # ... omitted.

      got_input => sub {
        my $new_time = $_[KERNEL]->delay_adjust(
          $_[HEAP]{input_timeout}, 60
        );
        print(
          "Refreshed the input timeout.  Next may occur at ",
          strftime("%F %T", gmtime($new_time)), "\n"
        );
      },
    }
  );

On failure it returns Boolean false and sets $! to a reason for the
failure.  See the explanation of $! for alarm_adjust().

=head4 delay_remove is not needed

There is no delay_remove().  Timers are all identical internally, so
alarm_remove() will work with timer IDs returned by delay_set().

=head4 delay_remove_all is not needed

There is no delay_remove_all().  Timers are all identical internally,
so alarm_remove_all() clears them all regardless how they were
created.

=head2 Session Identifiers (IDs and Aliases)

A session may be referred to by its object references (either blessed
or stringified), a session ID, or one or more symbolic names we call
aliases.

Every session is represented by an object, so session references are
fairly straightforward.  POE supports the use of stringified session
references for convenience and also as a form of weak reference.

  POE::Session->create(
    inline_states => {
      _start => sub { $_[KERNEL]->alias_set("echoer") },
      ping => sub {
        $_[KERNEL]->post( $_[SENDER], "pong", @_[ARG0..$#_] );
      }
    }
  );

Or responding via stringified $_[SENDER]:

  POE::Session->create(
    inline_states => {
      _start => sub { $_[KERNEL]->alias_set("echoer") },
      ping => sub {
        $_[KERNEL]->post( "$_[SENDER]", "pong", @_[ARG0..$#_] );
      }
    }
  );

Every session is assigned a unique ID at creation time.  No two active
sessions will have the same ID, but IDs may be reused over time.  The
combination of a kernel ID and a session ID should be sufficient as a
global unique identifier.

  POE::Session->create(
    inline_states => {
      _start => sub { $_[KERNEL]->alias_set("echoer") },
      ping => sub {
        $_[KERNEL]->delay(
          pong_later => rand(5), $_[SENDER]->ID, @_[ARG0..$#_]
        );
      },
      pong_later => sub {
        $_[KERNEL]->post( $_[ARG0], "pong", @_[ARG1..$#_] );
      }
    }
  );

Kernels also maintain a global session namespace from which sessions
may reserve symbolic aliases.  Once an alias is reserved, that alias
may be used to refer to the session wherever a session may be
specified.

In the previous examples, each echoer service has set an "echoer"
alias.  Another session can post a ping request to the echoer session
by using that alias rather than a session object or ID.  For example:

  POE::Session->create(
    inline_states => {
      _start => sub { $_[KERNEL]->post(echoer => ping => "whee!" ) },
      pong => sub { print "@_[ARG0..$#_]\n" }
    }
  );

A session with an alias will not stop until all other activity has
stopped.  Aliases are treated as a kind of event watcher.  The events
come from active sessions.  Aliases therefore become useless when
there are no active sessions left.  Rather than leaving the program
running in a "zombie" state, POE detects this deadlock condition and
triggers a cleanup.  TODO See the discussion of SIGIDLE in the signals
section.

=head3 alias_set ALIAS

alias_set() enters an ALIAS for the current session into POE::Kernel's
dictionary.  The ALIAS may then be used nearly everywhere a session
reference, stringified reference, or ID is expected.

Sessions may have more than one alias.  Each alias must be defined in
a separate alias_set() call.  A single alias may not refer to more
than one session.

Multiple alias examples are above.

alias_set() returns 0 on success, or a nonzero failure indicator:
EEXIST ("File exists") indicates that the alias is already assigned to
to a different session.

=head3 alias_remove ALIAS

alias_remove() removes an ALIAS for the current session from
POE::Kernel's dictionary.  The ALIAS will no longer refer to the
current session.  This does not negatively affect events already
posted to POE's queue.  Alias resolution occurs at post() time, not at
delivery time.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->alias_set("short_window");
        $_[KERNEL]->delay(close_window => 1);
      },
      close_window => {
        $_[KERNEL]->alias_remove("short_window");
      }
    }
  );

alias_remove() returns 0 on success or a nonzero failure code:  ESRCH
("No such process") indicates that the ALIAS is not currently in
POE::Kernel's dictionary.  EPERM ("Operation not permitted") means
that the current session may not remove the ALIAS because it is in use
by some other session.

=head3 alias_resolve ALIAS

alias_resolve() returns a session reference corresponding to a given
ALIAS.  Actually, the ALIAS may be a stringified session reference, a
session ID, or an alias previously registered by alias_set().

One use for alias_resolve() is to detect whether another session has
gone away:

  unless (defined $_[KERNEL]->alias_resolve("Elvis")) {
    print "Elvis has left the building.\n";
  }

As previously mentioned, alias_resolve() returns a session reference
or undef on failure.  Failure also sets $! to ESRCH ("No such
process") when the ALIAS is not currently in POE::Kernel's dictionary.

=head3 alias_list [SESSION_REFERENCE]

alias_list() returns a list of aliases associated with a specific
SESSION, or with the current session if SESSION is omitted.
alias_list() returns an empty list if the requested SESSION has no
aliases.

SESSION may be a session reference (blessed or stringified), a session
ID, or a session alias.

  POE::Session->create(
    inline_states => {
      $_[KERNEL]->alias_set("mi");
      print(
        "The names I call myself: ",
        join(", ", $_[KERNEL]->alias_resolve()),
        "\n"
      );
    }
  );

=head3 ID_id_to_session SESSION_ID

ID_id_to_session() translates a session ID into a session reference.
It's a special-purpose subset of alias_resolve(), so it's a little
faster and somewhat less flexible.

  unless (defined $_[KERNEL]->ID_id_to_session($session_id)) {
    print "Session $session_id doesn't exist.\n";
  }

ID_id_to_session() returns undef if a lookup failed.  $! will be set
to ESRCH ("No such process").

=head3 ID_session_to_id SESSION_REFERENCE

ID_session_to_id() converts a blessed or stringified SESSION_REFERENCE
into a session ID.  It's more practical for strigified references, as
programs can call the POE::Session ID() method on the blessed ones.
These statements are equivalent:

  $id = $_[SENDER]->ID();
  $id = $_[KERNEL]->ID_session_to_id($_[SENDER]);
  $id = $_[KERNEL]->ID_session_to_id("$_[SENDER]");

As with other POE::Kernel lookup methods, ID_session_to_id() returns
undef on failure, setting $! to ESRCH ("No such process").

=head2 I/O Watchers (Selects)

No event system would be complete without the ability to
asynchronously watch for I/O events.  POE::Kernel implements the
lowest level watchers, which are called "selects" because they were
historically implemented using Perl's built-in select(2) function.

Applications handle I/O readiness events by performing some activity
on the underlying filehandle.  Read-readiness might be handled by
reading from the handle.  Write-readiness by writing to it.

All I/O watcher events include two parameters.  C<ARG0> contains the
handle that is ready for work.  C<ARG1> contains an integer describing
what's ready.

  sub handle_io {
    my ($handle, $mode) = @_[ARG0, ARG1];
    print "File $handle is ready for ";
    if ($mode == 0) {
      print "reading";
    }
    elsif ($mode == 1) {
      print "writing";
    }
    elsif ($mode == 2) {
      print "out-of-band reading";
    }
    else {
      die "unknown mode $mode";
    }
    print "\n";
    # ... do something here
  }

The remaining parameters, C<@_[ARG2..$%_]>, contain additional
parameters that were passed to the POE::Kernel method that created the
watcher.

POE::Kernel conditions filehandles to be 8-bit clean and non-blocking.
Programs that need them conditioned differently should set them up
after starting POE I/O watchers.

I/O watchers will prevent sessions from stopping.

=head3 select_read FILE_HANDLE [, EVENT_NAME [, ADDITIONAL_PARAMETERS] ]

select_read() starts or stops the current session from watching for
incoming data on a given FILE_HANDLE.  The watcher is started if
EVENT_NAME is specified, or stopped if it's not.
ADDITIONAL_PARAMETERS, if specified, will be passed to the EVENT_NAME
handler as C<@_[ARG2..$#_]>.

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[HEAP]{socket} = IO::Socket::INET->new(
          PeerAddr => "localhost",
          PeerPort => 25,
        );
        $_[KERNEL]->select_read( $_[HEAP]{socket}, "got_input" );
        $_[KERNEL]->delay(timed_out => 1);
      },
      got_input => sub {
        my $socket = $_[ARG0];
        while (sysread($socket, my $buf = "", 8192)) {
          print $buf;
        }
      },
      timed_out => sub {
        $_[KERNEL]->select_read( delete $_[HEAP]{socket} );
      },
    }
  );

select_read() does not return anything significant.

=head3 select_write FILE_HANDLE [, EVENT_NAME [, ADDITIONAL_PARAMETERS] ]

select_write() follows the same semantics as select_read(), but it
starts or stops a watcher that looks for write-readiness.  That is,
when EVENT_NAME is delivered, it means that FILE_HANDLE is ready to be
written to.

TODO - Practical example here.

select_write() does not return anything significant.

=head3 select_expedite FILE_HANDLE [, EVENT_NAME [, ADDITIONAL_PARAMETERS] ]

select_expedite() does the same sort of thing as select_read() and
select_write(), but it watches a FILE_HANDLE for out-of-band data
ready to be input from a FILE_HANDLE.  Hardly anybody uses this, but
it exists for completeness' sake.

An EVENT_NAME event will be delivered whenever the FILE_HANDLE can be
read from out-of-band.  Out-of-band data is considered "expedited"
because it is often ahead of a socket's normal data.

select_expedite() does not return anything significant.

TODO - Practical example here.

=head3 select_pause_read FILE_HANDLE

select_pause_read() is a lightweight way to pause a FILE_HANDLE input
watcher without performing all the bookkeeping of a select_read().
It's used with select_resume_read() to implement input flow control.

Input that occurs on FILE_HANDLE will backlog in the operating system
buffers until select_resume_read() is called.

A side effect of bypassing the select_read() bookkeeping is that a
paused FILE_HANDLE will not prematurely stop the current session.

select_pause_read() does not return anything significant.

TODO - Practical example here.

=head3 select_resume_read FILE_HANDLE

select_resume_read() resumes a FILE_HANDLE input watcher that was
previously paused by select_pause_read().  See select_pause_read() for
more discussion on lightweight input flow control.

Data backlogged in the operating system due to a select_pause_read()
call will become available after select_resume_read() is called.

select_resume_read() does not return anything significant.

TODO - Practical example here.

=head3 select_pause_write FILE_HANDLE

select_pause_write() pauses a FILE_HANDLE output watcher the same way
select_pause_read() does for input.  Please see select_pause_read()
for further discusssion.

TODO - Practical example here.

=head3 select_resume_write FILE_HANDLE

select_resume_write() resumes a FILE_HANDLE output watcher the same
way that select_resume_read() does for input.  See
select_resume_read() for further discussion.

TODO - Practical example here.

=head3 select FILE_HANDLE [, EV_READ [, EV_WRITE [, EV_EXPEDITE [, ARGS] ] ] ]

POE::Kernel's select() method sets or clears a FILE_HANDLE's read,
write and expedite watchers at once.  It's a little more expensive
than calling select_read(), select_write() and select_expedite()
manually, but it's significantly more convenient.

Defined event names enable their corresponding watchers, and undefined
event names disable them.  This turns off all the watchers for a
FILE_HANDLE:

  sub stop_io {
    $_[KERNEL]->select( $_[HEAP]{file_handle} );
  }

This statement:

  $_[KERNEL]->select( $file_handle, undef, "write_event", @stuff );

is equivalent to:

  $_[KERNEL]->select_read( $file_handle );
  $_[KERNEL]->select_write( $file_handle, "write_event", @stuff );
  $_[KERNEL]->select_expedite( $file_handle );

POE::Kernel's select() should not be confused with Perl's built-in
select() function.

As with the other I/O watcher methods, select() does not return a
meaningful value.

=head2 Session Management

Sessions are dynamic.  They may be created and destroyed during a
program's lifespan.  When a session is created, it becomes the "child"
of the current session.  The creator---the current session---becomes
its "parent" session.  This is loosely modeled after UNIX processes.

The most common session management is done by creating new sessions
and allowing them to eventually stop.

Every session has a parent, even the very first session created.
Sessions without obvious parents are children of the program's
POE::Kernel instance.

Child sessions will keep their parents active.  See L<Session
Lifespans> for more about why sessions stay alive.

The parent/child relationship tree also governs the way many signals
are dispatched.  See L<Signal Watchers> for more information on that.

=head3 Session Management Events (_start, _stop, _parent, _child)

POE::Kernel provides four session management events: _start, _stop,
_parent and _child.  They are invoked synchronously whenever a session
is newly created or just about to be destroyed.

=over 2

=item

_start should be familiar by now.  POE calls it to initialize a newly
created session.  What is not readily apparent, however, is that it is
invoked before the POE::Session constructor returns.

The _start event's "sender" is the new session's creator and current
parent.

The _start handler's return value is passed to the parent session in a
_child event, along with the notification that the parent's new child
was created successfully.

_start and _child are invoked before the POE::Session constructor
returns.

=item

_stop is a little more mysterious.  POE calls a _stop handler when a
session is irrevocably about to be destroyed.  Part of session
destruction is the forcible reclamation of its resources (events,
timers, message events, etc.) so it's not possible to post() a message
from _stop's handler.  A program is free to try, but the event will be
destroyed before it has a chance to be dispatched.

the _stop handler's return value is passed to the parent's _child
event, along with the notification that the child session is in the
process of stopping.

_stop is invoked when a session has no further reason to live.  The
corresponding _child handler is invoked synchronously along with
_stop.

=item

_parent is used to notify a child session when its parent has changed.
This usually happens when a session is first created.  It can also
happen when a child session is detached from its parent.

=item

_child notifies one session when a child session has been created,
destroyed, or reassigned to or from another parent.  It's usually
dispatched when sessions are created or destroyed.  It can also happen
when a session is detached from its parent.

_child includes some information in the "arguments" portion of @_.
Typically ARG0, ARG1 and ARG2, but these may be overridden by a
different POE::Session class:

ARG0 contains a string describing what has happened to the child.  The
string may be 'create' (the child session has been created), 'gain'
(the child has been given by another session), or 'lose' (the child
session has stopped or been given away).

In all cases, ARG1 contains a reference to the child session.

In the 'create' case, ARG2 holds the value returned by the child
session's _start handler.  Likewise, ARG2 holds the _stop handler's
return value for the 'lose' case.

=back

The events are delivered in specific orders:

When a new session is created.  (1) The session's constructor is
called.  (2) The session is put into play.  That is, POE::Kernel
enters the session into its bookkeeping.  (3) The new session receives
_start.  (4) The parent session receves _child with 'create', the new
session reference, and the new session's _start's return value.  (5)
The session's constructor returns.

When an old session stops.  (1) If the session has children of its
own, they are given to the session's parent.  This triggers one or
more _child ('gain') events in the parent, and a _parent in each
child.  (2) Once divested of its children, the stopping session
receives a _stop event.  (3) The stopped session's parent receives a
_child ('lose') event with the departing child's reference and _stop
handler's return value.  (4) The stopped session is removed from play,
as are all its remaining resources.  (5) The parent session is checked
for idleness.  If so, garbage collection will commence on it, and it
too will be stopped

When a session is detached from its parent.  (1) The parent session of
the session being detached is notified with a _child ('lose') event.
The _stop handler's return value is undef since the child is not
actually stopping.  (2) The detached session is notified that its new
parent is POE::Kernel itself.  (3) POE::Kernel's bookkeeping data is
adjusted to reflect the change of parentage.  (4) The old parent
session is checked for idleness.  If so, garbage collection will
commence on it, and it too will be stopped

=head3 Session Management Methods

These methods allow sessions to be detached from their parents in the
rare cases where the parent/child relationship gets in the way.

=head4 detach_child CHILD_SESSION

detach_child() detaches a particular CHILD_SESSION from the current
session.  On success, the CHILD_SESSION will become a child of the
POE::Kernel instance, and detach_child() will return true.  On failure
however, detach_child() returns false and sets $! to explain the
nature of the failure:

ESRCH ("No such process").  The CHILD_SESSION is not a valid session.

EPERM ("Operation not permitted").  The CHILD_SESSION exists, but it
is not a child of the current session.

detach_child() will generate _parent and/or _child events to the
appropriate sessions.  See L<Session Management Events> for a detailed
explanation of these events.

TODO - Chart the events generated, and the order in which they are
dispatched.

=head4 detach_myself

detach_myself() detaches the current session from its current parent.
The new parent will be the running POE::Kernel instance.  It returns
true on success.  On failure it returns false and sets $! to
explain the nature of the failure:

EPERM ("Operation not permitted").  The current session is alreay a
child of POE::Kernel, so it may not be detached.

detach_child() will generate _parent and/or _child events to the
appropriate sessions.  See L<Session Manaement Events> for a detailed
explanation of these events.

TODO - Chart the events generated, and the order in which they are
dispatched.

=head3 Signals

POE::Kernel provides methods through which a program can register
interest in signals that come along, can deliver its own signals
without resorting to system calls, and can indicate that signals have
been handled so that defauld behaviors are not necessary.

Signals are action at a distance by nature, and their implementation
requires widespread synchronization between sessions (and re-entrancy
in the dispatcher, but that's an implementation detail).  Perfecting
the semantics has proven difficult, but POE tries to do the right
thing whenever possible.

POE does not register %SIG handlers for signals until sig() is called
to watch for them.  Therefore a signal's default behavior occurs for
unhandled signals.  That is, SIGINT will gracelessly stop a program,
SIGWINCH will do nothing, SIGTSTP will pause a program, and so on.

=head4 Signal Classes (benign, terminal and nonmaskable)

There are three signal classes.  Each class defines a default behavior
for the signal and whether the default can be overridden.  They are:

=over 2

=item

Benign, advisory, or informative signals.  These are three names for
the same signal class.  Signals in this class notify a session of an
event but do not terminate the session if they are not handled.

=item

Terminal signals will kill sessions if they are not handled by a
sig_handled() call.  The OS signals that usually kill or dump a
process are considered terminal in POE, but they never trigger a
coredump.  These are: HUP, INT, QUIT and TERM.

There are two terminal signals created by and used within POE: IDLE
and DIE.  The IDLE signal is used to notify leftover sessions that a
program has run out of things to do.  DIE notifies sessions that a
Perl exception has occurred.  See L<Exception Handling> for details.

=item

Nonmaskable signals are terminal regardless whether sig_handled() is
called.  The term comes from "NMI", the nonmaskable CPU interrupt
usually generated by an unrecoverable hardware exception.

Sessions that receive a nonmaskable signal will unavoidably stop.  POE
implements two nonmaskable signals:

ZOMBIE.  This nonmaskable signal is fired if a program has received an
IDLE signal but neither restarted nor exited.  The program has become
a zombie (that is, it's neither dead nor alive, and only exists to
consume memory).  The ZOMBIE signal acts livke a cricket bat to the
head, bringing the zombie down, for good.

UIDESTROY.  This nonmaskable signal indicates that a program's user
interface has been closed, and the program should take the user's hint
and buzz off as well.  It's usually generated when a particular GUI
widget is closed.

=back

=head3 Common Signal Dispatching

Most signals are not dispatched to a single session.  POE's session
lineage (parents and children) form a sort of family tree.  When a
signal is sent to a session, it first passes through any children (and
grandchildren, and so on) that are also interested in the signale

In the case of terminal signals, if any of the sessions a signal
passes through calls sig_handled(), then the signal is considered
taken care of.  However if none of them do, then the entire session
tree rooted at the destination session is terminated.  For example,
consider this tree of sessions:

  POE::Kernel
    Session 2
      Session 4
      Session 5
    Session 3
      Session 6
      Session 7

POE::Kernel is the parent of sessions 2 and 3.  Session 2 is the
parent of sessions 4 and 5.  And session 3 is the parent of 6 and 7.

A signal sent to Session 2 may also be dispatched to sessionl 4 and 5
because they are 2's children.  Sessions 4 and 5 will only receive the
signal if they have registered the appropriate watcher.

The program's POE::Kernel instance is considered to be a session for
the purpose of signal dispatch.  So any signal sent to POE::Kernel
will propagate through every interested session in the entire program.
This is in fact how OS signals are handled: A global signal handler is
registered to forward the signal to POE::Kernel.

=head3 Special Signal Semantics (SIGCHLD, SIGPIPE and SIGWINCH)

Certain signals have special semantics.

=head4 SIGCHLD (also known as SIGCLD)

Both SIGCHLD and SIGCLD indicate that a child process has exited or
been terminated by some signal.  The actual signal name varies between
operating systems, but POE uses "CHLD" regardless.

Interest in SIGCHLD is registered using the sig_child() method.  The
sig() method also works, but it's not as nice.

The SIGCHLD event includes three parameters: C<ARG0> contains the
string 'CHLD' (even if the OS calls it SIGCLD, SIGMONKEY, or something
else).  C<ARG1> contains the process ID of the finished child process.
And C<ARG2> holds the value of C<$?> for the finished process.

SIGCHLD is not handled ny registering a %SIG handler, although it may
be in the future.  For now, POE polls for child processes using a
non-blocking waitpid() call.  This is much more portable and reliable
than setting $SIG{CHLD}, although it's somewhat less responsive.

=head4 SIGPIPE

SIGPIPE is rarely used since POE provides events that do the same
thing.  Nevertheless SIGPIPE is supported if you need it.  Unlike most
events, however, SIGPIPE is dispatched directly to the active session
when it's caught.  Barring race conditions, the active session should
be the one that caused the OS to send the signal in the first place.

The SIGPIPE signal will still propagate to child sessions.

=head4 SIGWINCH

Window resizes can generate a large number of signals very quickly.
This may not be a problem when using perl 5.8.0 or later, but earlier
versions may not take kindly to such abuse.  You have been warned.

=head3 Exception Handling

TODO - Document exception handling.

By the way, POE::Kernel's built-in exception handling can be disabled
by setting the C<POE::Kernel::CATCH_EXCEPTIONS> constant to zero.  As
with other compile-time configuration constants, it must be set before
POE::Kernel is compiled:

  BEGIN {
    package POE::Kernel;
    use constant CATCH_EXCEPTIONS => 0;
  }
  use POE;

or

  sub POE::Kernel::CATCH_EXCEPTIONS () { 0 }
  use POE;

=head2 Signal Watcher Methods

And finally the methods themselves.

=head3 sig SIGNAL_NAME [, EVENT_NAME]

sig() registers or unregisters an EVENT_NAME event for a particular
SIGNAL_NAME.  The event is registered if EVENT_NAME is defined,
otherwise the SIGNAL_NAME handler is unregistered.  This does indded
imply that a session can register only one handler per SIGNAL_NAME.
Subsequent registration attempts will replace the old handler.

SIGNAL_NAMEs are generally the same as members of %SIG, with two
exceptions.  First, "CLD" is an alias for "CHLD" (although see
sig_child()).  And second, it's possible to send and handle signals
that have no basis in the operating system.

  sub handle_start {
    $_[KERNEL]->sig( INT => "event_ui_shutdown" );
    $_[KERNEL]->sig( bat => "holy_searchlight_batman" );
    $_[KERNEL]->sig( signal => "main_screen_turn_on" );
  }

The operating system may never be able to generate the last two
signals, but a POE session can by using POE::Kernel's signal() method.

Later on the session may decide not to handle the signals:

  sub handle_ui_shutdown {
    $_[KERNEL]->sig( "INT" );
    $_[KERNEL]->sig( "bat" );
    $_[KERNEL]->sig( "signal" );
  }

More than one session may register interest in the same signal, and a
session may clear its own signal watchers without affecting those in
other sessions.

sig() does not return a meaningful value.

=head3 sig_child PROCESS_ID [, EVENT_NAME [, ARGS_LIST] ]

sig_child() is a convenient way to deliver an EVENT_NAME event with an
optional ARGS_LIST when a particular PROCESS_ID has exited.  The
watcher can be cleared prematurely by calling sig_child() with just
the PROCESS_ID.

A session may register as many sig_child() handlers as necessary, but
there may only be one per PROCESS_ID.

sig_child() watchers are one-shot.  They automatically unregister
themselves once the EVENT_NAME has been delivered.

sig_child() watchers keep a session alive for as long as they are
active.

sig_chid() does not return a meaningful value.

TODO - Example

=head3 sig_handled

sig_handled() informs the POE::Kernel instance that the currently
dispatched signal has been handled by the currently active session.
If the signal is terminal, the sig_handled() call prevents POE::Kernel
from stopping the sessions that received the signal.

A single signal may be dispatched to several sessions.  Only one needs
to call sig_handled() to prevent the entire group from being stopped.
If none of them call it, however, then they are all stopped together.

TODO - Example

sig_handled() does not return a meaningful value.

=head3 signal SESSION, SIGNAL_NAME [, ARGS_LIST]

signal() posts a SIGNAL_NAME signal to a specific SESSION with an
optional ARGS_LIST that will be passed to every intersted handler.  As
mentioned elsewhere, the signal may be delivered to SESSION's
children, grandchildren, and so on.  And if SESSION is the POE::Kernel
itself, then all interested sessions will receive the signal.

It is possible to send a signal() in POE that doesn't exist in the
operating system.  signal() places the signal directly into POE's
event queue as if they came from the operating system, but they are
not limited to signals recognized by kill().  POE uses a few of these
fictitious signals for its own global notifications.

For example:

  sub some_event_handler {
    # Turn on all main screens.
    $_[KERNEL]->signal( $_[KERNEL], "signal" );
  }

signal() returns true on success.  On failure, it returns false after
setting $! to explain the nature of the failure:

ESRCH ("No such process").  The SESSION does not exist.

=head3 signal_ui_destroy WIDGET_OBJECT

signal_ui_destroy() associates the destruction of a particular
WIDGET_OBJECT with the complete destruction of the program's user
interface.  When the WIDGET_OBJECT destructs, POE::Kernel issues the
nonmaskable UIDESTROY signal, which quickly triggers mass destruction
of all active sessions.  POE::Kernel->run() returns shortly
thereafter.

  sub setup_ui {
    $_[HEAP]{main_widget} = Gtk->new("toplevel");
    # ... populate the main widget here ...
    $_[KERNEL]->signal_ui_destroy( $_[HEAP]{main_widget} );
  }

=head3 TODO

TODO - See if there is anything to migrate over from POE::Session?

=head2 Event Handler (State) Management

The term "state" is often used in place of "event handler", especially
when treating sessions as event driven state machines.

State management methods let sessions hot swap their event handlers at
runtime.

It would be rude to change another session's handlers, so these
methods only affect the current one.

There is only one method in this group.  Since it may be called in
several different ways, it may be easier to understand if each is
documented separately.

=head3 state EVENT_NAME [, CODE_REFERNCE]

state() sets or removes a handler for EVENT_NAME in the current
session.  The function referred to by CODE_REFERENCE will be called
whenever EVENT_NAME events are dispatched to the current session.  If
CODE_REFERENCE is omitted, the handler for EVENT_NAME will be removed.

A session may only have one handler for a given EVENT_NAME.
Subsequent attempts to set an EVENT_NAME handler will replace earlier
handlers with the same name.

  # Stop paying attention to input.  Say goodbye, and
  # trigger a socket close when the message is sent.
  sub send_final_response {
    $_[HEAP]{wheel}->put("KTHXBYE");
    $_[KERNEL]->state( 'on_client_input' );
    $_[KERNEL]->state( on_flush => \&close_connection );
  }

=head3 state EVENT_NAME [, OBJECT_REFERENCE [, OBJECT_METHOD_NAME] ]

Set or remove a handler for EVENT_NAME in the current session.  If an
OBJECT_REFERENCE is given, that object will handle the event.  An
optional OBJECT_METHOD_NAME may be provided.  If the method name is
not given, POE will look for a method matching the EVENT_NAME instead.
If the OBJECT_REFERENCE is omitted, the handler for EVENT_NAME will be
removed.

A session may only have one handler for a given EVENT_NAME.
Subsequent attempts to set an EVENT_NAME handler will replace earlier
handlers with the same name.

TODO - Example.

=head3 state EVENT_NAME [, CLASS_NAME [, CLASS_METHOD_NAME] ]

This form of state() call is virtually identical to that of the object
form.

Set or remove a handler for EVENT_NAME in the current session.  If an
CLASS_NAME is given, that class will handle the event.  An optional
CLASS_METHOD_NAME may be provided.  If the method name is not given,
POE will look for a method matching the EVENT_NAME instead.  If the
CLASS_NAME is omitted, the handler for EVENT_NAME will be removed.

A session may only have one handler for a given EVENT_NAME.
Subsequent attempts to set an EVENT_NAME handler will replace earlier
handlers with the same name.

TODO - Example.

=head2 Reference Counters

The methods in this section manipulate reference counters on the
current session or another session.

Each session has a namespace for user-manipulated reference counters.
These namespaces are associated with the target SESSION_ID for the
reference counter methods, not the caller.  Nothing currently prevents
one session from decrementing a reference counter that was incremented
by another, but this behavior is not guaranteed to remain.  For now,
it's up to the users of these methods to choose obscure counter names
to avoid conflicts.

Reference counting is a big part of POE's magic.  Various objects
(mainly event watchers and components) hold references to the sessions
that own them.  L<Session Lifespans> explains the concept in more
detail.

The ability to keep a session alive is sometimes useful in an
application or library.  For example, a component may hold a reference
to another session while it processes a request from that session.  In
doing so, the component guarantees that the requester is still around
when a response is eventually ready.

=head3 refcount_increment SESSION_ID, COUNTER_NAME

refcount_increment() increases the value of the COUNTER_NAME reference
counter for the session identified by a SESSION_ID.  To discourage the
use of session references, the refcount_increment() target session
must be specified by its session ID.

The target session will not stop until the value of any and all of its
COUNTER_NAME reference counters are zero.  (Actually, it may stop in
some cases, such as failing to handle a terminal signal.)

Negative reference counters are legal.  They still must be incremented
back to zero before a session is elegible for stopping.

  sub handle_request {
    # Among other things, hold a reference count on the sender.
    $_[KERNEL]->refcount_increment( $_[SENDER]->ID, "pending request");
    $_[HEAP]{requesters}{$request_id} = $_[SENDER]->ID;
  }

For this to work, the session needs a way to remember the
$_[SENDER]->ID for a given request.  Customarily the session generates
a request ID and uses that to track the request until it is fulfilled

refcount_increment() returns true on success or false on failure.
Furthermore, $! is set on failure to one of:

ESRCH: The SESSION_ID does not refer to a currently active session.

=head3 refcount_decrement SESSION_ID, COUNTER_NAME

refcount_decrement() reduces the value of the COUNTER_NAME reference
counter for the session identified by a SESSION_ID.  It is the
counterpoint for refcount_increment().  Please see
refcount_increment() for more context.

  sub finally_send_response {
    # Among other things, release the reference count for the
    # requester.
    my $requester_id = delete $_[HEAP]{requesters}{$request_id};
    $_[KERNEL]->refcount_increment( $requester_id, "pending request");
  }

The reqester's $_[SENDER]->ID is remembered and removed from the hear
(lest there be memory leaks).  It's used to decrement the reference
counter that was incremented at the start of the request.

refcount_decrement() returns true on success or false on failure.
Furthermore, $! is set on failure to one of:

ESRCH: The SESSION_ID does not refer to a currently active session.

=head2 Kernel State Accessors

POE::Kernel provides a few accessors into its massive brain so that
library developers may have convenient access to necessary data
without relying on their callers to provide it.

These accessors expose ways to break session encapsulation.  Please
use them sparingly and carefully.

=head3 get_active_session

get_active_session() returns a reference to the session that is
currently running, or a reference to the program's POE::Kernel
instance if no session is running at that moment.  The value is
equivalent to $_[SESSION].

This method was added for libraries that need $_[SESSION] but don't
want to include it as a parameter in their APIs.

TODO - Example.

=head3 get_active_event

get_active_event() returns the name of the event currently being
dispatched.  It returns an empty string when called outside event
dispatch.  The value is equivalent to $_[STATE].

TODO - Example.

=head3 get_event_count

get_event_count() returns the number of events pending in POE's event
queue.  It is exposed for POE::Loop class authors.  It may be
deprecated in the future.

=head3 get_next_event_time

get_next_event_time() returns the time the next event is due, in a
form compatible with the UNIX time() function.  It is exposed for
POE::Loop class authors.  It may be deprecated in the future.

=head2 Kernel Debugging

TODO

=head1 Session Lifespans

TODO - Explain what keeps sessions alive.

-><- END OF NEW DOCUMENTATION


=head1 PUBLIC KERNEL METHODS

-><- - Taking text from here.

=head2 Kernel Internal Methods

Those methods are primarily used by other POE modules and are not for public
consumption.

=over 2

=item new

Accepts no arguments and returns a singleton POE::Kernel instance.

=item session_alloc

Allocates a session in the Kernel - does not create it! Fires off the _start event
with the arguments given.

=back

=head1 Using POE with Other Event Loops

POE::Kernel supports any number of event loops.  Four are included in
the base distribution, and others are available on the CPAN.  POE's
public interfaces remain the same regardless of the event loop being
used.

There are three ways to load an alternate event loop.  The simplest is
to load the event loop before loading POE::Kernel.  Remember that POE
loads POE::Kernel internally.

  use Gtk;
  use POE;

POE::Kernel detects that Gtk has been loaded, and it loads the
appropriate internal code to use it.

You can also specify which loop to load directly.  Event loop bridges
are named "POE::Loop::$loop_module", where $loop_module is the name of
the module, with "::" translated to underscores.  For example:

  use POE qw( Loop::Event_Lib );

would load POE::Loop::Event_Lib (which may or may not be on CPAN).

If you'd rather use POE::Kernel directly, it has a different import
syntax:

  use POE::Kernel { loop => "Tk" };

The four event loops included in POE's distribution:

POE's default select() loop.  It is included so at least something
will work on any given platform.

Event.pm.  This provides compatibility with other modules requiring
Event's loop.  It may also introduce safe signals in versions of Perl
prior to 5.8, should you need them.

Gtk and Tk event loops.  These are included to support graphical
toolkits.  Others are on the CPAN, including Gtk2 and hopefully WxPerl
soon.  When using Tk with POE, POE supplies an already-created
$poe_main_window variable to use for your main window.  Calling Tk's
MainWindow->new() often has an undesired outcome.

IO::Poll.  This is potentially more efficient than POE's default
select() code in large scale clients and servers.

Many external event loops expect plain coderefs as callbacks.
POE::Session has postback() and callback() methods that create
callbacks suitable for external event loops.  In turn, they post() or
call() POE event handlers.

=head2 Kernel's Debugging Features

POE::Kernel contains a number of assertion and tracing flags.  They
were originally created to debug POE::Kernel itself, but they are also
useful for tracking down other problems.

Assertions are the quiet ones.  They only create output when something
catastrophic has happened.  That output is almost always fatal.  They
are mainly used to check the sanity of POE's internal data structures.

Traces are assertions' annoying cousins.  They noisily report on the
status of a running POE::Kernel instance, but they are never fatal.

Assertions and traces incur performance penalties when enabled.  It's
probably a bad idea to enable them in live systems.  They are all
disabled by default.

Assertion and tracing flags can be defined before POE::Kernel is first
used.

  # Turn on everything.
  sub POE::Kernel::ASSERT_DEFAULT () { 1 }
  sub POE::Kernel::TRACE_DEFAULT  () { 1 }
  use POE;  # Includes POE::Kernel

It is also possible to enable them using shell environment variables.
The environment variables follow the same names as the constants in
this section, but "POE_" is prepended to them.

  POE_ASSERT_DEFAULT=1 POE_TRACE_DEFAULT=1 ./my_poe_program

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
heaps when they finally DESTROY.  It is indispensable for finding
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

stat_getdata() returns a hash of various statistics and their values
The statistics are calculated using a sliding window and vary over
time as a program runs.

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

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Redocument.
# TODO - Test the examples.
