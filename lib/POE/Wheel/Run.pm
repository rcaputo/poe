# $Id$

package POE::Wheel::Run;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use Carp qw(carp croak);
use POSIX qw(
  sysconf setsid _SC_OPEN_MAX ECHO ICANON IEXTEN ISIG BRKINT ICRNL
  INPCK ISTRIP IXON CSIZE PARENB OPOST TCSANOW
);

use POE qw( Wheel Pipe::TwoWay Pipe::OneWay Driver::SysRW Filter::Line );

BEGIN {
  die "$^O does not support fork()\n" if $^O eq 'MacOS';

  local $SIG{'__DIE__'} = 'DEFAULT';
  eval    { require IO::Pty; };
  if ($@) { eval 'sub PTY_AVAILABLE () { 0 }';  }
  else {
    IO::Pty->import();
    eval 'sub PTY_AVAILABLE () { 1 }';
  }

  if (POE::Kernel::RUNNING_IN_HELL) {
      eval    { require Win32::Console; };
      if ($@) { die "Win32::Console failed to load:\n$@" }
      else    { Win32::Console->import(); };

      eval    { require Win32API::File; };
      if ($@) { die "Win32API::File but failed to load:\n$@" }
      else    { Win32API::File->import( qw(FdGetOsFHandle) ); };
  }

  # How else can I get them out?!
  if (eval '&IO::Tty::Constant::TIOCSCTTY') {
    *TIOCSCTTY = *IO::Tty::Constant::TIOCSCTTY;
  }
  else {
    eval 'sub TIOCSCTTY () { undef }';
  }

  if (eval '&IO::Tty::Constant::CIBAUD') {
    *CIBAUD = *IO::Tty::Constant::CIBAUD;
  }
  else {
    eval 'sub CIBAUD () { undef; }';
  }

  if (
    eval '&IO::Tty::Constant::TIOCSWINSZ' and
    eval '&IO::Tty::Constant::TIOCGWINSZ'
  ) {
    *TIOCSWINSZ = *IO::Tty::Constant::TIOCSWINSZ;
    *TIOCGWINSZ = *IO::Tty::Constant::TIOCGWINSZ;
  }
  else {
    eval 'sub TIOCSWINSZ () { undef; }';
    eval 'sub TIOCGWINSZ () { undef; }';
  }

  # Determine the most file descriptors we can use.
  my $max_open_fds;
  eval {
    $max_open_fds = sysconf(_SC_OPEN_MAX);
  };
  $max_open_fds = 1024 unless $max_open_fds;
  eval "sub MAX_OPEN_FDS () { $max_open_fds }";
  die if $@;
};

# Offsets into $self.
sub UNIQUE_ID     () {  0 }
sub ERROR_EVENT   () {  1 }
sub CLOSE_EVENT   () {  2 }
sub PROGRAM       () {  3 }
sub CHILD_PID     () {  4 }
sub CONDUIT_TYPE  () {  5 }
sub IS_ACTIVE     () {  6 }
sub CLOSE_ON_CALL () {  7 }
sub STDIO_TYPE    () {  8 }

sub HANDLE_STDIN  () {  9 }
sub FILTER_STDIN  () { 10 }
sub DRIVER_STDIN  () { 11 }
sub EVENT_STDIN   () { 12 }
sub STATE_STDIN   () { 13 }
sub OCTETS_STDIN  () { 14 }

sub HANDLE_STDOUT () { 15 }
sub FILTER_STDOUT () { 16 }
sub DRIVER_STDOUT () { 17 }
sub EVENT_STDOUT  () { 18 }
sub STATE_STDOUT  () { 19 }

sub HANDLE_STDERR () { 20 }
sub FILTER_STDERR () { 21 }
sub DRIVER_STDERR () { 22 }
sub EVENT_STDERR  () { 23 }
sub STATE_STDERR  () { 24 }

# Used to work around a bug in older perl versions.
sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type needs an even number of parameters" if @_ & 1;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if @_ and ref($_[0]) eq 'POE::Kernel';

  croak "$type requires a working Kernel" unless defined $poe_kernel;

  my $program = delete $params{Program};
  croak "$type needs a Program parameter" unless defined $program;

  my $prog_args = delete $params{ProgramArgs};
  $prog_args = [] unless defined $prog_args;
  croak "ProgramArgs must be an ARRAY reference"
    unless ref($prog_args) eq "ARRAY";

  my $priority_delta = delete $params{Priority};
  $priority_delta = 0 unless defined $priority_delta;

  my $close_on_call = delete $params{CloseOnCall};
  $close_on_call = 0 unless defined $close_on_call;

  my $user_id  = delete $params{User};
  my $group_id = delete $params{Group};

  # The following $stdio_type is new.  $conduit is kept around for now
  # to preserve the logic of the rest of the module.  This change
  # allows a Session using POE::Wheel::Run to define the type of pipe
  # to be created for stdin and stdout.  Read the POD on Conduit.
  # However, the documentation lies, because if Conduit is undefined,
  # $stdio_type is set to undefined (so the default pipe type provided
  # by POE::Pipe::TwoWay will be used). Otherwise, $stdio_type
  # determines what type of pipe Pipe:TwoWay creates unless it's
  # 'pty'.

  my $conduit = delete $params{Conduit};
  my $stdio_type;
  if (defined $conduit) {
    croak "$type\'s Conduit type ($conduit) is unknown"
      if (
        $conduit ne 'pipe' and
        $conduit ne 'pty'  and
        $conduit ne 'socketpair' and
        $conduit ne 'inet'
      );
    unless ($conduit eq "pty") {
      $stdio_type = $conduit;
      $conduit = "pipe";
    }
  }
  else {
    $conduit = "pipe";
  }

  my $winsize = delete $params{Winsize};
  croak "Winsize needs to be an array ref"
    if (defined($winsize) and ref($winsize) ne 'ARRAY');

  my $stdin_event  = delete $params{StdinEvent};
  my $stdout_event = delete $params{StdoutEvent};
  my $stderr_event = delete $params{StderrEvent};

  if ($conduit eq 'pty' and defined $stderr_event) {
    carp "ignoring StderrEvent with pty conduit";
    undef $stderr_event;
  }

  croak "$type needs at least one of StdinEvent, StdoutEvent or StderrEvent"
    unless(
      defined($stdin_event) or defined($stdout_event) or
      defined($stderr_event)
    );

  my $stdio_driver  = delete $params{StdioDriver}
    || POE::Driver::SysRW->new();
  my $stdin_driver  = delete $params{StdinDriver}  || $stdio_driver;
  my $stdout_driver = delete $params{StdoutDriver} || $stdio_driver;
  my $stderr_driver = delete $params{StderrDriver}
    || POE::Driver::SysRW->new();

  my $stdio_filter  = delete $params{Filter};
  my $stdin_filter  = delete $params{StdinFilter};
  my $stdout_filter = delete $params{StdoutFilter};
  my $stderr_filter = delete $params{StderrFilter};

  if (defined $stdio_filter) {
    croak "Filter and StdioFilter cannot be used together"
      if defined $params{StdioFilter};
    croak "Replace deprecated Filter with StdioFilter and StderrFilter"
      if defined $stderr_event and not defined $stderr_filter;
    carp "Filter is deprecated.  Please try StdioFilter and/or StderrFilter";
  }
  else {
    $stdio_filter = delete $params{StdioFilter};
  }
  $stdio_filter = POE::Filter::Line->new(Literal => "\n")
    unless defined $stdio_filter;

  $stdin_filter  = $stdio_filter unless defined $stdin_filter;
  $stdout_filter = $stdio_filter unless defined $stdout_filter;

  if ($conduit eq 'pty' and defined $stderr_filter) {
    carp "ignoring StderrFilter with pty conduit";
    undef $stderr_filter;
  }
  else {
    $stderr_filter = POE::Filter::Line->new(Literal => "\n")
      unless defined $stderr_filter;
  }

  croak "$type needs either StdioFilter or StdinFilter when using StdinEvent"
    if defined($stdin_event) and not defined($stdin_filter);
  croak "$type needs either StdioFilter or StdoutFilter when using StdoutEvent"
    if defined($stdout_event) and not defined($stdout_filter);
  croak "$type needs a StderrFilter when using StderrEvent"
    if defined($stderr_event) and not defined($stderr_filter);

  my $error_event = delete $params{ErrorEvent};
  my $close_event = delete $params{CloseEvent};

  my $no_setsid = delete $params{NoSetSid};

  # Make sure the user didn't pass in parameters we're not aware of.
  if (scalar keys %params) {
    carp(
      "unknown parameters in $type constructor call: ",
      join(', ', sort keys %params)
    );
  }

  my (
    $stdin_read, $stdout_write, $stdout_read, $stdin_write,
    $stderr_read, $stderr_write,
  );

  # Create a semaphore pipe.  This is used so that the parent doesn't
  # begin listening until the child's stdio has been set up.
  my ($sem_pipe_read, $sem_pipe_write) = POE::Pipe::OneWay->new();
  croak "could not create semaphore pipe: $!" unless defined $sem_pipe_read;

  # Use IO::Pty if requested.  IO::Pty turns on autoflush for us.
  if ($conduit eq 'pty') {
    croak "IO::Pty is not available" unless PTY_AVAILABLE;

    $stdin_write = $stdout_read = IO::Pty->new();
    croak "could not create master pty: $!" unless defined $stdout_read;
  }

  # Use pipes otherwise.
  elsif ($conduit eq 'pipe') {
    # We make more pipes than strictly necessary in case someone wants
    # to turn some on later.  Uses a TwoWay pipe for STDIN/STDOUT and
    # a OneWay pipe for STDERR.  This may save 2 filehandles if
    # socketpair() is available and no other $stdio_type is selected.
    ($stdin_read, $stdout_write, $stdout_read, $stdin_write) =
      POE::Pipe::TwoWay->new($stdio_type);
    croak "could not make stdin pipe: $!"
      unless defined $stdin_read and defined $stdin_write;
    croak "could not make stdout pipe: $!"
      unless defined $stdout_read and defined $stdout_write;

    ($stderr_read, $stderr_write) = POE::Pipe::OneWay->new();
    croak "could not make stderr pipes: $!"
      unless defined $stderr_read and defined $stderr_write;
  }

  # Sanity check.
  else {
    croak "unknown conduit type $conduit";
  }

  # Fork!  Woo-hoo!
  my $pid = fork;

  # Stdio should not be tied.  Resolves rt.cpan.org ticket 1648.
  if (tied *STDOUT) {
    carp "Cannot redirect into tied STDOUT.  Untying it";
    untie *STDOUT;
  }
  if (tied *STDERR) {
    carp "Cannot redirect into tied STDERR.  Untying it";
    untie *STDERR;
  }

  # Child.  Parent side continues after this block.
  unless ($pid) {
    croak "couldn't fork: $!" unless defined $pid;

    # If running pty, we delay the slave side creation 'til after
    # doing the necessary bits to become our own [unix] session.
    if ($conduit eq 'pty') {

      # Become a new unix session.
      # Program 19.3, APITUE.  W. Richard Stevens built my hot rod.
      eval 'setsid()' unless $no_setsid;

      # Open the slave side of the pty.
      $stdin_read = $stdout_write = $stderr_write = $stdin_write->slave();
      croak "could not create slave pty: $!" unless defined $stdin_read;

      # Acquire a controlling terminal.  Program 19.3, APITUE.
      if (defined TIOCSCTTY and not defined CIBAUD) {
        ioctl( $stdin_read, TIOCSCTTY, 0 );
      }

      # Put the pty conduit (slave side) into "raw" or "cbreak" mode,
      # per APITUE 19.4 and 11.10.
      my $tio = POSIX::Termios->new();
      $tio->getattr(fileno($stdin_read));
      my $lflag = $tio->getlflag;
      $lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
      $tio->setlflag($lflag);
      my $iflag = $tio->getiflag;
      $iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
      $tio->setiflag($iflag);
      my $cflag = $tio->getcflag;
      $cflag &= ~(CSIZE | PARENB);
      $tio->setcflag($cflag);
      my $oflag = $tio->getoflag;
      $oflag &= ~(OPOST);
      $tio->setoflag($oflag);
      $tio->setattr(fileno($stdin_read), TCSANOW);

      # Set the pty conduit (slave side) window size to our window
      # size.  APITUE 19.4 and 19.5.
      if (defined TIOCGWINSZ) {
        my $window_size = '!' x 25;
        if (-t STDIN and !$winsize) {
          ioctl( STDIN, TIOCGWINSZ, $window_size ) or die $!;
        }
        $window_size = pack('SSSS', @$winsize) if ref($winsize);
        if ($window_size ne '!' x 25) {
          ioctl( $stdin_read, TIOCSWINSZ, $window_size ) or die $!;
        }
        else {
          carp "STDIN is not a terminal.  Can't set slave pty's window size";
        }
      }
    }

    # Reset all signals in the child process.  POE's own handlers are
    # silly to keep around in the child process since POE won't be
    # using them.
    my @safe_signals = $poe_kernel->_data_sig_get_safe_signals();
    @SIG{@safe_signals} = ("DEFAULT") x @safe_signals;

    # -><- How to pass events to the parent process?  Maybe over a
    # expedited (OOB) filehandle.

    # Fix the child process' priority.  Don't bother doing this if it
    # wasn't requested.  Can't emit events on failure because we're in
    # a separate process, so just fail quietly.

    if ($priority_delta) {
      eval {
        if (defined(my $priority = getpriority(0, $$))) {
          unless (setpriority(0, $$, $priority + $priority_delta)) {
            # -><- can't set child priority
          }
        }
        else {
          # -><- can't get child priority
        }
      };
      if ($@) {
        # -><- can't get child priority
      }
    }

    # Fix the group ID.  -><- Add getgrnam so group IDs can be
    # specified by name.  -><- Warn if not superuser to begin with.
    if (defined $group_id) {
      $( = $) = $group_id;
    }

    # Fix the user ID.  -><- Add getpwnam so user IDs can be specified
    # by name.  -><- Warn if not superuser to begin with.
    if (defined $user_id) {
      $< = $> = $user_id;
    }

    # Close what the child won't need.
    close $stdin_write;
    close $stdout_read;
    close $stderr_read if defined $stderr_read;

    # Need to close on Win32 because std handles aren't dup'ed, no
    # harm elsewhere.  Close STDERR later to not influence possible
    # die.
    close STDIN;
    close STDOUT;

    # Redirect STDIN from the read end of the stdin pipe.
    open( STDIN, "<&" . fileno($stdin_read) )
      or die "can't redirect STDIN in child pid $$: $!";

    # Redirect STDOUT to the write end of the stdout pipe.
    # The STDOUT_FILENO check snuck in on a patch.  I'm not sure why
    # we care what the file descriptor is.
    open( STDOUT, ">&" . fileno($stdout_write) )
      or die "can't redirect stdout in child pid $$: $!";

    # Need to close on Win32 because std handles aren't dup'ed, no
    # harm elsewhere
    close STDERR;

    # Redirect STDERR to the write end of the stderr pipe.  If the
    # stderr pipe's undef, then we use STDOUT.
    # The STDERR_FILENO check snuck in on a patch.  I'm not sure why
    # we care what the file descriptor is.
    open( STDERR, ">&" . fileno($stderr_write) )
      or die "can't redirect stderr in child: $!";

    # Make STDOUT and/or STDERR auto-flush.
    select STDERR;  $| = 1;
    select STDOUT;  $| = 1;

    # Tell the parent that the stdio has been set up.
    close $sem_pipe_read;
    print $sem_pipe_write "go\n";
    close $sem_pipe_write;

    if (POE::Kernel::RUNNING_IN_HELL)  {
      # The Win32 pseudo fork sets up the std handles in the child
      # based on the true win32 handles For the exec these get
      # remembered, so manipulation of STDIN/OUT/ERR is not enough.
      # Only necessary for the exec, as Perl CODE subroutine goes
      # through 0/1/2 which are correct.  But ofcourse that coderef
      # might invoke exec, so better do it regardless.
      # HACK: Using Win32::Console as nothing else exposes SetStdHandle
      Win32::Console::_SetStdHandle(
        STD_INPUT_HANDLE(),
        FdGetOsFHandle(fileno($stdin_read))
      );
      Win32::Console::_SetStdHandle(
        STD_OUTPUT_HANDLE(),
        FdGetOsFHandle(fileno($stdout_write))
      );
      Win32::Console::_SetStdHandle(
        STD_ERROR_HANDLE(),
        FdGetOsFHandle(fileno($stderr_write))
      );
    }

    # Exec the program depending on its form.
    if (ref($program) eq 'CODE') {

      # Close any close-on-exec file descriptors.  Except STDIN,
      # STDOUT, and STDERR, of course.
      if ($close_on_call) {
        for (0..MAX_OPEN_FDS-1) {
          next if fileno(STDIN) == $_;
          next if fileno(STDOUT) == $_;
          next if fileno(STDERR) == $_;
          POSIX::close($_);
        }
      }

      $program->(@$prog_args);

      # In case flushing them wasn't good enough.
      close STDOUT if defined fileno(STDOUT);
      close STDERR if defined fileno(STDERR);

      # Try to exit without triggering END or object destructors.
      # Give up with a plain exit if we must.
      # On win32 cannot _exit as it will kill *all* threads, meaning parent too
      unless (POE::Kernel::RUNNING_IN_HELL) {
    eval { POSIX::_exit(0);  };
    eval { kill KILL => $$;  };
    eval { exec("$^X -e 0"); };
      };
      exit(0);
    } else {
  if (ref($program) eq 'ARRAY') {
    exec(@$program, @$prog_args)
      or die "can't exec (@$program) in child pid $$: $!";
  }
  else {
    exec(join(" ", $program, @$prog_args))
      or die "can't exec ($program) in child pid $$: $!";
  }
    }
    die "insanity check passed";
  }

  # Parent here.  Close what the parent won't need.
  close $stdin_read   if defined $stdin_read;
  close $stdout_write if defined $stdout_write;
  close $stderr_write if defined $stderr_write;

  my $handle_count = 0;
  $handle_count++ if defined $stdout_read;
  $handle_count++ if defined $stderr_read;

  my $self = bless [
    &POE::Wheel::allocate_wheel_id(),  # UNIQUE_ID
    $error_event,   # ERROR_EVENT
    $close_event,   # CLOSE_EVENT
    $program,       # PROGRAM
    $pid,           # CHILD_PID
    $conduit,       # CONDUIT_TYPE
    $handle_count,  # IS_ACTIVE
    $close_on_call, # CLOSE_ON_CALL
    $stdio_type,    # STDIO_TYPE
    # STDIN
    $stdin_write,   # HANDLE_STDIN
    $stdin_filter,  # FILTER_STDIN
    $stdin_driver,  # DRIVER_STDIN
    $stdin_event,   # EVENT_STDIN
    undef,          # STATE_STDIN
    0,              # OCTETS_STDIN
    # STDOUT
    $stdout_read,   # HANDLE_STDOUT
    $stdout_filter, # FILTER_STDOUT
    $stdout_driver, # DRIVER_STDOUT
    $stdout_event,  # EVENT_STDOUT
    undef,          # STATE_STDOUT
    # STDERR
    $stderr_read,   # HANDLE_STDERR
    $stderr_filter, # FILTER_STDERR
    $stderr_driver, # DRIVER_STDERR
    $stderr_event,  # EVENT_STDERR
    undef,          # STATE_STDERR
  ], $type;

  # Wait here while the child sets itself up.
  <$sem_pipe_read>;
  close $sem_pipe_read;
  close $sem_pipe_write;

  $self->_define_stdin_flusher();
  $self->_define_stdout_reader() if defined $stdout_read;
  $self->_define_stderr_reader() if defined $stderr_read;

  return $self;
}

#------------------------------------------------------------------------------
# Define the internal state that will flush output to the child
# process' STDIN pipe.

sub _define_stdin_flusher {
  my $self = shift;

  # Read-only members.  If any of these change, then the write state
  # is invalidated and needs to be redefined.
  my $unique_id    = $self->[UNIQUE_ID];
  my $driver       = $self->[DRIVER_STDIN];
  my $error_event  = \$self->[ERROR_EVENT];
  my $close_event  = \$self->[CLOSE_EVENT];
  my $stdin_filter = $self->[FILTER_STDIN];
  my $stdin_event  = \$self->[EVENT_STDIN];
  my $is_active    = \$self->[IS_ACTIVE];

  # Read/write members.  These are done by reference, to avoid pushing
  # $self into the anonymous sub.  Extra copies of $self are bad and
  # can prevent wheels from destructing properly.
  my $stdin_octets = \$self->[OCTETS_STDIN];

  # Register the select-write handler.
  $poe_kernel->state(
    $self->[STATE_STDIN] = ref($self) . "($unique_id) -> select stdin",
    sub {                             # prevents SEGV
      0 && CRIMSON_SCOPE_HACK('<');
                                      # subroutine starts here
      my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

      $$stdin_octets = $driver->flush($handle);

      # When you can't write, nothing else matters.
      if ($!) {
        $$error_event && $k->call(
          $me, $$error_event,
          'write', ($!+0), $!, $unique_id, "STDIN"
        );
        $k->select_write($handle);
      }

      # Could write, or perhaps couldn't but only because the
      # filehandle's buffer is choked.
      else {

        # All chunks written; fire off a "flushed" event.
        unless ($$stdin_octets) {
          $k->select_pause_write($handle);
          $$stdin_event && $k->call($me, $$stdin_event, $unique_id);
        }
      }
    }
  );

  $poe_kernel->select_write($self->[HANDLE_STDIN], $self->[STATE_STDIN]);

  # Pause the write select immediately, unless output is pending.
  $poe_kernel->select_pause_write($self->[HANDLE_STDIN])
    unless ($self->[OCTETS_STDIN]);
}

#------------------------------------------------------------------------------
# Define the internal state that will read input from the child
# process' STDOUT pipe.  This is virtually identical to
# _define_stderr_reader, but they aren't implemented as a common
# function for speed reasons.

sub _define_stdout_reader {
  my $self = shift;

  # Register the select-read handler for STDOUT.
  if (defined $self->[HANDLE_STDOUT]) {

    # If any of these change, then the read state is invalidated and
    # needs to be redefined.
    my $unique_id     = $self->[UNIQUE_ID];
    my $driver        = $self->[DRIVER_STDOUT];
    my $error_event   = \$self->[ERROR_EVENT];
    my $close_event   = \$self->[CLOSE_EVENT];
    my $stdout_filter = $self->[FILTER_STDOUT];
    my $stdout_event  = \$self->[EVENT_STDOUT];
    my $is_active     = \$self->[IS_ACTIVE];

    if (
      $stdout_filter->can("get_one") and
      $stdout_filter->can("get_one_start")
    ) {
      $poe_kernel->state(
        $self->[STATE_STDOUT] = ref($self) . "($unique_id) -> select stdout",
        sub {
          # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');

          # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            $stdout_filter->get_one_start($raw_input);
            while (1) {
              my $next_rec = $stdout_filter->get_one();
              last unless @$next_rec;
              foreach my $cooked_input (@$next_rec) {
                $k->call($me, $$stdout_event, $cooked_input, $unique_id);
              }
            }
          }
          else {
            $$error_event and
              $k->call(
                $me, $$error_event,
                'read', ($!+0), $!, $unique_id, 'STDOUT'
              );
            unless (--$$is_active) {
              $k->call( $me, $$close_event, $unique_id )
                if defined $$close_event;
            }
            $k->select_read($handle);
          }
        }
      );
    }

    # Otherwise we can't get one.
    else {
      $poe_kernel->state(
        $self->[STATE_STDOUT] = ref($self) . "($unique_id) -> select stdout",
        sub {
          # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');

          # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$stdout_filter->get($raw_input)}) {
              $k->call($me, $$stdout_event, $cooked_input, $unique_id);
            }
          }
          else {
            $$error_event and
              $k->call(
                $me, $$error_event,
                'read', ($!+0), $!, $unique_id, 'STDOUT'
              );
            unless (--$$is_active) {
              $k->call( $me, $$close_event, $unique_id )
                if defined $$close_event;
            }
            $k->select_read($handle);
          }
        }
      );
    }

    # register the state's select
    $poe_kernel->select_read($self->[HANDLE_STDOUT], $self->[STATE_STDOUT]);
  }

  # Register the select-read handler for STDOUT.
  else {
    $poe_kernel->select_read($self->[HANDLE_STDOUT])
      if defined $self->[HANDLE_STDOUT];
  }
}

#------------------------------------------------------------------------------
# Define the internal state that will read input from the child
# process' STDERR pipe.

sub _define_stderr_reader {
  my $self = shift;

  # Register the select-read handler for STDERR.
  if (defined $self->[HANDLE_STDERR]) {
    # If any of these change, then the read state is invalidated and
    # needs to be redefined.
    my $unique_id     = $self->[UNIQUE_ID];
    my $driver        = $self->[DRIVER_STDERR];
    my $error_event   = \$self->[ERROR_EVENT];
    my $close_event   = \$self->[CLOSE_EVENT];
    my $stderr_filter = $self->[FILTER_STDERR];
    my $stderr_event  = \$self->[EVENT_STDERR];
    my $is_active     = \$self->[IS_ACTIVE];

    if (
      $stderr_filter->can("get_one") and
      $stderr_filter->can("get_one_start")
    ) {
      $poe_kernel->state(
        $self->[STATE_STDERR] = ref($self) . "($unique_id) -> select stderr",
        sub {
          # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');

          # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            $stderr_filter->get_one_start($raw_input);
            while (1) {
              my $next_rec = $stderr_filter->get_one();
              last unless @$next_rec;
              foreach my $cooked_input (@$next_rec) {
                $k->call($me, $$stderr_event, $cooked_input, $unique_id);
              }
            }
          }
          else {
            $$error_event and
              $k->call(
                $me, $$error_event,
                'read', ($!+0), $!, $unique_id, 'STDERR'
              );
            unless (--$$is_active) {
              $k->call( $me, $$close_event, $unique_id )
                if defined $$close_event;
            }
            $k->select_read($handle);
          }
        }
      );
    }

    # Otherwise we can't get_one().
    else {
      $poe_kernel->state(
        $self->[STATE_STDERR] = ref($self) . "($unique_id) -> select stderr",
        sub {
          # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');

          # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$stderr_filter->get($raw_input)}) {
              $k->call($me, $$stderr_event, $cooked_input, $unique_id);
            }
          }
          else {
            $$error_event and
              $k->call(
                $me, $$error_event,
                'read', ($!+0), $!, $unique_id, 'STDERR'
              );
            unless (--$$is_active) {
              $k->call( $me, $$close_event, $unique_id )
                if defined $$close_event;
            }
            $k->select_read($handle);
          }
        }
      );
    }

    # register the state's select
    $poe_kernel->select_read($self->[HANDLE_STDERR], $self->[STATE_STDERR]);
  }

  # Register the select-read handler for STDERR.
  else {
    $poe_kernel->select_read($self->[HANDLE_STDERR])
      if defined $self->[HANDLE_STDERR];
  }
}

#------------------------------------------------------------------------------
# Redefine events.

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  my ($redefine_stdin, $redefine_stdout, $redefine_stderr) = (0, 0, 0);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'StdinEvent') {
      $self->[EVENT_STDIN] = $event;
      $redefine_stdin = 1;
    }
    elsif ($name eq 'StdoutEvent') {
      $self->[EVENT_STDOUT] = $event;
      $redefine_stdout = 1;
    }
    elsif ($name eq 'StderrEvent') {
      if ($self->[CONDUIT_TYPE] ne 'pty') {
        $self->[EVENT_STDERR] = $event;
        $redefine_stderr = 1;
      }
      else {
        carp "ignoring StderrEvent on a pty conduit";
      }
    }
    elsif ($name eq 'ErrorEvent') {
      $self->[ERROR_EVENT] = $event;
    }
    elsif ($name eq 'CloseEvent') {
      $self->[CLOSE_EVENT] = $event;
    }
    else {
      carp "ignoring unknown Run parameter '$name'";
    }
  }

  $self->_define_stdin_flusher() if defined $redefine_stdin;
  $self->_define_stdout_reader() if defined $redefine_stdout;
  $self->_define_stderr_reader() if defined $redefine_stderr;
}

#------------------------------------------------------------------------------
# Destroy the wheel.

sub DESTROY {
  my $self = shift;

  # Turn off the STDIN thing.
  if ($self->[HANDLE_STDIN]) {
    $poe_kernel->select($self->[HANDLE_STDIN]);
    $self->[HANDLE_STDIN] = undef;
  }
  if ($self->[STATE_STDIN]) {
    $poe_kernel->state($self->[STATE_STDIN]);
    $self->[STATE_STDIN] = undef;
  }

  if ($self->[HANDLE_STDOUT]) {
    $poe_kernel->select($self->[HANDLE_STDOUT]);
    $self->[HANDLE_STDOUT] = undef;
  }
  if ($self->[STATE_STDOUT]) {
    $poe_kernel->state($self->[STATE_STDOUT]);
    $self->[STATE_STDOUT] = undef;
  }

  if ($self->[HANDLE_STDERR]) {
    $poe_kernel->select($self->[HANDLE_STDERR]);
    $self->[HANDLE_STDERR] = undef;
  }
  if ($self->[STATE_STDERR]) {
    $poe_kernel->state($self->[STATE_STDERR]);
    $self->[STATE_STDERR] = undef;
  }

  &POE::Wheel::free_wheel_id($self->[UNIQUE_ID]);
}

#------------------------------------------------------------------------------
# Queue input for the child process.

sub put {
  my ($self, @chunks) = @_;
  if (
    $self->[OCTETS_STDIN] =  # assignment on purpose
    $self->[DRIVER_STDIN]->put($self->[FILTER_STDIN]->put(\@chunks))
  ) {
    $poe_kernel->select_resume_write($self->[HANDLE_STDIN]);
  }

  # No watermark.
  return 0;
}

#------------------------------------------------------------------------------
# Pause and resume various input events.

sub pause_stdout {
  my $self = shift;
  return unless defined $self->[HANDLE_STDOUT];
  $poe_kernel->select_pause_read($self->[HANDLE_STDOUT]);
}

sub pause_stderr {
  my $self = shift;
  return unless defined $self->[HANDLE_STDERR];
  $poe_kernel->select_pause_read($self->[HANDLE_STDERR]);
}

sub resume_stdout {
  my $self = shift;
  return unless defined $self->[HANDLE_STDOUT];
  $poe_kernel->select_resume_read($self->[HANDLE_STDOUT]);
}

sub resume_stderr {
  my $self = shift;
  return unless defined $self->[HANDLE_STDERR];
  $poe_kernel->select_resume_read($self->[HANDLE_STDERR]);
}

# Shutdown the pipe that leads to the child's STDIN.
sub shutdown_stdin {
  my $self = shift;
  return unless defined $self->[HANDLE_STDIN];

  $poe_kernel->select_write($self->[HANDLE_STDIN], undef);

  eval { local $^W = 0; shutdown($self->[HANDLE_STDIN], 1) };
  close $self->[HANDLE_STDIN] if $@;
}

#------------------------------------------------------------------------------
# Redefine filters, one at a time or at once.  This is based on PG's
# code in Wheel::ReadWrite.

sub _transfer_stdout_buffer {
  my ($self, $buf) = @_;

  my $old_output_filter = $self->[FILTER_STDOUT];

  # Assign old buffer contents to the new filter, and send out any
  # pending packets.

  # Use "get_one" if the new filter implements it.
  if (defined $buf) {
    if (
      $old_output_filter->can("get_one") and
      $old_output_filter->can("get_one_start")
    ) {
      $old_output_filter->get_one_start($buf);

      # Don't bother to continue if the filter has switched out from
      # under our feet again.  The new switcher will finish the job.

      while ($self->[FILTER_STDOUT] == $old_output_filter) {
        my $next_rec = $old_output_filter->get_one();
        last unless @$next_rec;
        foreach my $cooked_input (@$next_rec) {
          $poe_kernel->call(
            $poe_kernel->get_active_session(), $self->[EVENT_STDOUT],
            $cooked_input, $self->[UNIQUE_ID]
          );
        }
      }
    }

    # Otherwise use the old get() behavior.
    else {
      foreach my $cooked_input (@{$self->[FILTER_STDOUT]->get($buf)}) {
        $poe_kernel->call(
          $poe_kernel->get_active_session(), $self->[EVENT_STDOUT],
          $cooked_input, $self->[UNIQUE_ID]
        );
      }
    }
  }
}

sub _transfer_stderr_buffer {
  my ($self, $buf) = @_;

  my $old_output_filter = $self->[FILTER_STDERR];

  # Assign old buffer contents to the new filter, and send out any
  # pending packets.

  # Use "get_one" if the new filter implements it.
  if (defined $buf) {
    if (
      $old_output_filter->can("get_one") and
      $old_output_filter->can("get_one_start")
    ) {
      $old_output_filter->get_one_start($buf);

      # Don't bother to continue if the filter has switched out from
      # under our feet again.  The new switcher will finish the job.

      while ($self->[FILTER_STDERR] == $old_output_filter) {
        my $next_rec = $old_output_filter->get_one();
        last unless @$next_rec;
        foreach my $cooked_input (@$next_rec) {
          $poe_kernel->call(
            $poe_kernel->get_active_session(), $self->[EVENT_STDERR],
            $cooked_input, $self->[UNIQUE_ID]
          );
        }
      }
    }

    # Otherwise use the old get() behavior.
    else {
      foreach my $cooked_input (@{$self->[FILTER_STDERR]->get($buf)}) {
        $poe_kernel->call(
          $poe_kernel->get_active_session(), $self->[EVENT_STDERR],
          $cooked_input, $self->[UNIQUE_ID]
        );
      }
    }
  }
}

sub set_stdio_filter {
  my ($self, $new_filter) = @_;
  $self->set_stdout_filter($new_filter);
  $self->set_stdin_filter($new_filter);
}

sub set_stdin_filter {
  my ($self, $new_filter) = @_;
  $self->[FILTER_STDIN] = $new_filter;
}

sub set_stdout_filter {
  my ($self, $new_filter) = @_;

  my $buf = $self->[FILTER_STDOUT]->get_pending();
  $self->[FILTER_STDOUT] = $new_filter;

  $self->_define_stdout_reader();
  $self->_transfer_stdout_buffer($buf);
}

sub set_stderr_filter {
  my ($self, $new_filter) = @_;

  my $buf = $self->[FILTER_STDERR]->get_pending();
  $self->[FILTER_STDERR] = $new_filter;

  $self->_define_stderr_reader();
  $self->_transfer_stderr_buffer($buf);
}

sub get_stdin_filter {
  my $self = shift;
  return $self->[FILTER_STDIN];
}

sub get_stdout_filter {
  my $self = shift;
  return $self->[FILTER_STDOUT];
}

sub get_stderr_filter {
  my $self = shift;
  return $self->[FILTER_STDERR];
}

#------------------------------------------------------------------------------
# Data accessors.

sub get_driver_out_octets {
  $_[0]->[OCTETS_STDIN];
}

sub get_driver_out_messages {
  $_[0]->[DRIVER_STDIN]->get_out_messages_buffered();
}

sub ID {
  $_[0]->[UNIQUE_ID];
}

sub PID {
  $_[0]->[CHILD_PID];
}

sub kill {
  my ($self, $signal) = @_;
  $signal = 'TERM' unless defined $signal;
  eval { kill $signal, $self->[CHILD_PID] };
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::Run - event driven fork/exec with added value

=head1 SYNOPSIS

  # Program may be scalar or \@array.
  $program = '/usr/bin/cat -';
  $program = [ '/usr/bin/cat', '-' ];

  $wheel = POE::Wheel::Run->new(
    Program     => $program,
    ProgramArgs => \@program_args,     # Parameters for $program.
    Priority    => +5,                 # Adjust priority.  May need to be root.
    User        => getpwnam('nobody'), # Adjust UID. May need to be root.
    Group       => getgrnam('nobody'), # Adjust GID. May need to be root.
    ErrorEvent  => 'oops',             # Event to emit on errors.
    CloseEvent  => 'child_closed',     # Child closed all output.

    StdinEvent  => 'stdin',  # Event to emit when stdin is flushed to child.
    StdoutEvent => 'stdout', # Event to emit with child stdout information.
    StderrEvent => 'stderr', # Event to emit with child stderr information.

    # Specify different I/O formats.
    StdinFilter  => POE::Filter::Line->new(),   # Child accepts input as lines.
    StdoutFilter => POE::Filter::Stream->new(), # Child output is a stream.
    StderrFilter => POE::Filter::Line->new(),   # Child errors are lines.

    # Set StdinFilter and StdoutFilter together.
    StdioFilter => POE::Filter::Line->new(),    # Or some other filter.

    # Specify different I/O methods.
    StdinDriver  => POE::Driver::SysRW->new(),  # Defaults to SysRW.
    StdoutDriver => POE::Driver::SysRW->new(),  # Same.
    StderrDriver => POE::Driver::SysRW->new(),  # Same.

    # Set StdinDriver and StdoutDriver together.
    StdioDriver  => POE::Driver::SysRW->new(),
  );

  print "Unique wheel ID is  : ", $wheel->ID;
  print "Wheel's child PID is: ", $wheel->PID;

  # Send something to the child's STDIN.
  $wheel->put( 'input for the child' );

  # Kill the child.
  $wheel->kill();  # TERM by default
  $wheel->kill(9);

=head1 DESCRIPTION

Wheel::Run spawns child processes and establishes non-blocking, event
based communication with them.

=head1 PUBLIC METHODS

=over 2

=item new LOTS_OF_STUFF

new() creates a new Run wheel.  If successful, the new wheel
represents a child process and the input, output and error pipes that
speak with it.

new() accepts lots of stuff.  Each parameter is name/value pair.

=over 2

=item Conduit

C<Conduit> describes how Wheel::Run should talk with the child
process.  By default it will try various forms of inter-process
communication to build a pipe between the parent and child processes.
If a particular method is preferred, it can be set to "pipe",
"socketpair", or "inet".  It may also be set to "pty" if the child
process should have its own pseudo tty.

The reasons to define this parameter would be if you want to use
"pty", if the default pipe type doesn't work properly on your
system, or the default pipe type's performance is poor.

Pty conduits require the IO::Pty module.

=item Winsize

C<Winsize> is only valid for C<Conduit = "pty"> and used to set the
window size of the pty device.

The window size is given as an array reference.  The first element is
the number of lines, the second the number of columns. The third and
the fourth arguments are optional and specify the X and Y dimensions
in pixels.

=item CloseOnCall

C<CloseOnCall> emulates the close-on-exec feature for child processes
which are not started by exec().  When it is set to 1, all open file
handles whose descriptors are greater than $^F are closed in the child
process.  This is only effective when POE::Wheel::Run is called with a
code reference for its Program parameter.

  CloseOnCall => 1,
  Program => \&some_function,

CloseOnCall defaults to 0 (off) to remain compatible with existing
programs.

For more details, please the discussion of $^F in L<perlvar>.

=item StdioDriver

=item StdinDriver

=item StdoutDriver

=item StderrDriver

These parameters change the drivers for Wheel::Run.  The default
drivers are created internally with C<<POE::Driver::SysRW->new()>>.

C<StdioDriver> changes both C<StdinDriver> and C<StdoutDriver> at the
same time.

=item CloseEvent

=item ErrorEvent

=item StdinEvent

=item StdoutEvent

=item StderrEvent

C<CloseEvent> contains the name of an event to emit when the child
process closes all its output handles.  This is a consistent
notification that the child will not be sending any more output.  It
does not, however, signal that the client process has stopped
accepting input.

C<ErrorEvent> contains the name of an event to emit if something
fails.  It is optional and if omitted, the wheel will not notify its
session if any errors occur.  The event receives 5 parameters as
follows: ARG0 = the return value of syscall(), ARG1 = errno() - the
numeric value of the error generated, ARG2 = error() - a descriptive
for the given error, ARG3 = the wheel id, and ARG4 = the handle on
which the error occurred (stdout, stderr, etc.)

Wheel::Run requires at least one of the following three events:

C<StdinEvent> contains the name of an event that Wheel::Run emits
whenever all its output has been flushed to the child process' STDIN
handle.

C<StdoutEvent> and C<StderrEvent> contain names of events that
Wheel::Run emits whenever the child process writes something to its
STDOUT or STDERR handles, respectively.

=item StdioFilter

=item StdinFilter

=item StdoutFilter

=item StderrFilter

C<StdioFilter> contains an instance of a POE::Filter subclass.  The
filter describes how the child process performs input and output.
C<Filter> will be used to describe the child's stdin and stdout
methods.  If stderr is also to be used, StderrFilter will need to be
specified separately.

C<Filter> is optional.  If left blank, it will default to an
instance of C<POE::Filter::Line->new(Literal => "\n");>

C<StdinFilter> and C<StdoutFilter> can be used instead of or in
addition to C<StdioFilter>.  They will override the default filter's
selection in situations where a process' input and output are in
different formats.

=item Group

C<Group> contains a numerical group ID that the child process should
run at.  This may not be meaningful on systems that have no concept of
group IDs.  The current process may need to run as root in order to
change group IDs.  Mileage varies considerably.

=item NoSetSid

When true, C<NoSetSid> disables setsid() in the child process.  By
default, setsid() is called to execute the child process in a separate
Unix session.

=item Priority

C<Priority> contains an offset from the current process's priority.
The child will be executed at the current priority plus the offset.
The priority offset may be negative, but the current process may need
to be running as root for that to work.

=item Program

C<Program> is the program to exec() once pipes and fork have been set
up.  C<Program>'s type determines how the program will be run.

If C<Program> holds a scalar, it will be executed as exec($scalar).
Shell metacharacters will be expanded in this form.

If C<Program> holds an array reference, it will executed as
exec(@$array).  This form of exec() doesn't expand shell
metacharacters.

If C<Program> holds a code reference, it will be called in the forked
child process, and then the child will exit.  This allows Wheel::Run
to fork off bits of long-running code which can accept STDIN input and
pass responses to STDOUT and/or STDERR.  Note, however, that POE's
services are effectively disabled in the child process.

L<perlfunc> has more information about exec() and the different ways
to call it.

Note: Do not call exit() explicitly when executing a subroutine.
POE::Wheel::Run takes special care to avoid object destructors and END
blocks in the child process, and calling exit() will thwart that.  You
may see "POE::Kernel's run() method was never called." or worse.

=item ProgramArgs => ARRAY

If specified, C<ProgramArgs> should refer to a list of parameters for
the program being run.

  my @parameters = qw(foo bar baz);  # will be passed to Program
  ProgramArgs => \@parameters;

=back

=item event EVENT_TYPE => EVENT_NAME, ...

event() changes the event that Wheel::Run emits when a certain type of
event occurs.  C<EVENT_TYPE> may be one of the event parameters in
Wheel::Run's constructor.

  $wheel->event( StdinEvent  => 'new-stdin-event',
                 StdoutEvent => 'new-stdout-event',
               );

=item put LIST

put() queues a LIST of different inputs for the child process.  They
will be flushed asynchronously once the current state returns.  Each
item in the LIST is processed according to the C<StdinFilter>.

=item get_stdin_filter

=item get_stdout_filter

=item get_stderr_filter

Get C<StdinFilter>, C<StdoutFilter>, or C<StderrFilter> respectively.

=item set_stdio_filter FILTER_REFERENCE

Set C<StdinFilter> and C<StdoutFilter> at once.

=item set_stdin_filter FILTER_REFERENCE

=item set_stdout_filter FILTER_REFERENCE

=item set_stderr_filter FILTER_REFERENCE

Set C<StdinFilter>, C<StdoutFilter>, or C<StderrFilter> respectively.

=item pause_stdout

=item pause_stderr

=item resume_stdout

=item resume_stderr

Pause or resume C<StdoutEvent> or C<StderrEvent> events.  By using
these methods a session can control the flow of Stdout and Stderr
events coming in from this child process.

=item shutdown_stdin

Closes the child process' STDIN and stops the wheel from reporting
StdinEvent.  It is extremely useful for running utilities that expect
to receive EOF on their standard inputs before they respond.

=item ID

Returns the wheel's unique ID, which is not the same as the child
process' ID.  Every event generated by Wheel::Run includes a wheel ID
so that it can be matched up with its generator.  This lets a single
session manage several wheels without becoming confused about which
one generated what event.

=item PID

Returns the child process' ID.  It's useful for matching up to SIGCHLD
events, which include child process IDs as well, so that wheels can be
destroyed properly when children exit.

=item kill SIGNAL

Sends a signal to the child process.  It's useful for processes which
tend to be reluctant to exit when their terminals are closed.

The kill() method will send SIGTERM if SIGNAL is undef or omitted.

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item CloseEvent

CloseEvent contains the name of the event Wheel::Run emits whenever a
child process has closed all its output handles.  It signifies that
the child will not be sending more information.  In addition to the
usual POE parameters, each CloseEvent comes with one of its own:

C<ARG0> contains the wheel's unique ID.  This can be used to keep
several child processes separate when they're managed by the same
session.

A sample close event handler:

  sub close_state {
    my ($heap, $wheel_id) = @_[HEAP, ARG0];

    my $child = delete $heap->{child}->{$wheel_id};
    print "Child ", $child->PID, " has finished.\n";
  }

=item ErrorEvent

ErrorEvent contains the name of an event that Wheel::Run emits
whenever an error occurs.  Every error event comes with four
parameters:

C<ARG0> contains the name of the operation that failed.  It may be
'read' or 'write' or 'fork' or 'exec' or something.  The actual values
aren't yet defined.  Note: This is not necessarily a function name.

C<ARG1> and C<ARG2> hold numeric and string values for C<$!>,
respectively.

C<ARG3> contains the wheel's unique ID.

C<ARG4> contains the name of the child filehandle that has the error.
It may be "STDIN", "STDOUT", or "STDERR".  The sense of C<ARG0> will
be the opposite of what you might normally expect for these handles.
For example, Wheel::Run will report a "read" error on "STDOUT" because
it tried to read data from that handle.

A sample error event handler:

  sub error_state {
    my ($operation, $errnum, $errstr, $wheel_id) = @_[ARG0..ARG3];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
  }

=item StdinEvent

StdinEvent contains the name of an event that Wheel::Run emits
whenever everything queued by its put() method has been flushed to the
child's STDIN handle.

StdinEvent's C<ARG0> parameter contains its wheel's unique ID.

=item StdoutEvent

=item StderrEvent

StdoutEvent and StderrEvent contain names for events that Wheel::Run
emits whenever the child process makes output.  StdoutEvent contains
information the child wrote to its STDOUT handle, and StderrEvent
includes whatever arrived from the child's STDERR handle.

Both of these events come with two parameters.  C<ARG0> contains the
information that the child wrote.  C<ARG1> holds the wheel's unique
ID.

  sub stdout_state {
    my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
    print "Child process in wheel $wheel_id wrote to STDOUT: $input\n";
  }

  sub stderr_state {
    my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
    print "Child process in wheel $wheel_id wrote to STDERR: $input\n";
  }

=back

=head1 TIPS AND TRICKS

One common task is scrubbing a child process' environment.  This
amounts to clearing the contents of %ENV and setting it up with some
known, secure values.

Environment scrubbing is easy when the child process is running a
subroutine, but it's not so easy---or at least not as intuitive---when
executing external programs.

The way we do it is to run a small subroutine in the child process
that performs the exec() call for us.

  Program => \&exec_with_scrubbed_env,

  sub exec_with_scrubbed_env {
    delete @ENV{keys @ENV};
    $ENV{PATH} = "/bin";
    exec(@program_and_args);
  }

That deletes everything from the environment, sets a simple, secure
PATH, and executes a program with its arguments.

=head1 SEE ALSO

POE::Wheel.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Wheel::Run's constructor doesn't emit proper events when it fails.
Instead, it just dies, carps or croaks.

Filter changing hasn't been implemented yet.  Let the author know if
it's needed.  Better yet, patch the file based on the code in
Wheel::ReadWrite.

Priority is a delta; there's no way to set it directly to some value.

User must be specified by UID.  It would be nice to support login
names.

Group must be specified by GID.  It would be nice to support group
names.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
