# $Id$

package POE::Wheel::Run;

use strict;
use Carp;
use POSIX;  # termios stuff

use POE qw(Wheel Pipe::TwoWay Pipe::OneWay Driver::SysRW);

BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';
  eval    { require IO::Pty; };
  if ($@) { eval 'sub PTY_AVAILABLE () { 0 }';  }
  else {
    IO::Pty->import();
    eval 'sub PTY_AVAILABLE () { 1 }';
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

  if (eval '&IO::Tty::Constant::TIOCSWINSZ') {
    *TIOCSWINSZ = *IO::Tty::Constant::TIOCSWINSZ;
  }
  else {
    eval 'sub TIOCSWINSZ () { undef; }';
  }
};

# Offsets into $self.
sub UNIQUE_ID     () {  0 }
sub DRIVER        () {  1 }
sub ERROR_EVENT   () {  2 }
sub PROGRAM       () {  3 }
sub CHILD_PID     () {  4 }
sub CONDUIT_TYPE  () {  5 }

sub HANDLE_STDIN  () {  6 }
sub FILTER_STDIN  () {  7 }
sub EVENT_STDIN   () {  8 }
sub STATE_STDIN   () {  9 }
sub OCTETS_STDIN  () { 10 }

sub HANDLE_STDOUT () { 11 }
sub FILTER_STDOUT () { 12 }
sub EVENT_STDOUT  () { 13 }
sub STATE_STDOUT  () { 14 }

sub HANDLE_STDERR () { 15 }
sub FILTER_STDERR () { 16 }
sub EVENT_STDERR  () { 17 }
sub STATE_STDERR  () { 18 }

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

  my $priority_delta = delete $params{Priority};
  $priority_delta = 0 unless defined $priority_delta;

  my $user_id  = delete $params{User};
  my $group_id = delete $params{Group};

  my $conduit = delete $params{Conduit};
  $conduit = 'pipe' unless defined $conduit;
  croak "$type needs a known Conduit type (pty or pipe, not $conduit)"
    if $conduit ne 'pipe' and $conduit ne 'pty';

  my $stdin_event  = delete $params{StdinEvent};
  my $stdout_event = delete $params{StdoutEvent};
  my $stderr_event = delete $params{StderrEvent};

  if ($conduit eq 'pty' and defined $stderr_event) {
    carp "ignoring StderrEvent with pty conduit";
    undef $stderr_event;
  }

  croak "$type needs at least one of StdinEvent, StdoutEvent or StderrEvent"
    unless( defined($stdin_event) or defined($stdout_event) or
            defined($stderr_event)
          );

  my $all_filter    = delete $params{Filter};
  my $stdin_filter  = delete $params{StdinFilter};
  my $stdout_filter = delete $params{StdoutFilter};
  my $stderr_filter = delete $params{StderrFilter};

  $stdin_filter  = $all_filter unless defined $stdin_filter;
  $stdout_filter = $all_filter unless defined $stdout_filter;

  if (defined $stderr_filter) {
    if ($conduit eq 'pty') {
      carp "ignoring StderrFilter with pty conduit";
      undef $stderr_filter;
    }
  }
  else {
    $stderr_filter = $all_filter unless $conduit eq 'pty';
  }

  croak "$type needs either Filter or StdinFilter"
    if defined($stdin_event) and not defined($stdin_filter);
  croak "$type needs either Filter or StdoutFilter"
    if defined($stdout_event) and not defined($stdout_filter);
  croak "$type needs either Filter or StderrFilter"
    if defined($stderr_event) and not defined($stderr_filter);

  my $error_event   = delete $params{ErrorEvent};

  # Make sure the user didn't pass in parameters we're not aware of.
  if (scalar keys %params) {
    carp( "unknown parameters in $type constructor call: ",
          join(', ', sort keys %params)
        );
  }

  my ( $stdin_read, $stdout_write, $stdout_read, $stdin_write,
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
    # socketpair() is available.
    ($stdin_read, $stdout_write, $stdout_read, $stdin_write) =
      POE::Pipe::TwoWay->new();
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

  # Child.  Parent side continues after this block.
  unless ($pid) {
    croak "couldn't fork: $!" unless defined $pid;

    # If running pty, we delay the slave side creation 'til after
    # doing the necessary bits to become our own [unix] session.
    if ($conduit eq 'pty') {

      # Become a new unix session.
      # Program 19.3, APITUE.  W. Richard Stevens built my hot rod.
      eval 'setsid()';

      # Open the slave side of the pty.
      $stdin_read = $stdout_write = $stderr_write = $stdin_write->slave();
      croak "could not create slave pty: $!" unless defined $stdin_read;

      # Acquire a controlling terminal.  Program 19.3, APITUE.
      if (defined TIOCSCTTY and not defined CIBAUD) {
        ioctl( $stdin_read, TIOCSCTTY, 0 );
      }

      # Put the pty conduit into "raw" or "cbreak" mode, per APITUE
      # 19.4 and 11.10.
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
    }

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

    # Fix the user ID.  -><- Add getpwnam so user IDs can be specified
    # by name.  -><- Warn if not superuser to begin with.
    if (defined $user_id) {
      $< = $> = $user_id;
    }

    # Fix the group ID.  -><- Add getgrnam so group IDs can be
    # specified by name.  -><- Warn if not superuser to begin with.
    if (defined $group_id) {
      $( = $) = $group_id;
    }

    # Close what the child won't need.
    close $stdin_write;
    close $stdout_read;
    close $stderr_read if defined $stderr_read;

    # Redirect STDIN from the read end of the stdin pipe.
    open( STDIN, "<&" . fileno($stdin_read) )
      or die "can't redirect STDIN in child pid $$: $!";

    # Redirect STDOUT to the write end of the stdout pipe.
    open( STDOUT, ">&" . fileno($stdout_write) )
      or die "can't redirect stdout in child pid $$: $!";

    # Redirect STDERR to the write end of the stderr pipe.  If the
    # stderr pipe's undef, then we use STDOUT.
    open( STDERR, ">&" . fileno($stderr_write) )
      or die "can't redirect stderr in child: $!";

    # Make STDOUT and/or STDERR auto-flush.
    select STDERR;  $| = 1;
    select STDOUT;  $| = 1;

    # Tell the parent that the stdio has been set up.
    close $sem_pipe_read;
    print $sem_pipe_write "go\n";
    close $sem_pipe_write;

    # Exec the program depending on its form.
    if (ref($program) eq 'ARRAY') {
      exec(@$program) or die "can't exec (@$program) in child pid $$: $!";
    }
    elsif (ref($program) eq 'CODE') {
      $program->();

      # In case flushing them wasn't good enough.
      close STDOUT if defined fileno(STDOUT);
      close STDERR if defined fileno(STDERR);

      eval { POSIX::_exit(0); };
      eval { kill KILL => $$; };
      exit(0);
    }
    else {
      exec($program) or die "can't exec ($program) in child pid $$: $!";
    }

    die "insanity check passed";
  }

  # Parent here.  Close what the parent won't need.
  close $stdin_read   if defined $stdin_read;
  close $stdout_write if defined $stdout_write;
  close $stderr_write if defined $stderr_write;

  my $self = bless
    [ &POE::Wheel::allocate_wheel_id(),  # UNIQUE_ID
      POE::Driver::SysRW->new(),         # DRIVER
      $error_event,   # ERROR_EVENT
      $program,       # PROGRAM
      $pid,           # CHILD_PID
      $conduit,       # CONDUIT_TYPE
      # STDIN
      $stdin_write,   # HANDLE_STDIN
      $stdin_filter,  # FILTER_STDIN
      $stdin_event,   # EVENT_STDIN
      undef,          # STATE_STDIN
      0,              # OCTETS_STDIN
      # STDOUT
      $stdout_read,   # HANDLE_STDOUT
      $stdout_filter, # FILTER_STDOUT
      $stdout_event,  # EVENT_STDOUT
      undef,          # STATE_STDOUT
      # STDERR
      $stderr_read,   # HANDLE_STDERR
      $stderr_filter, # FILTER_STDERR
      $stderr_event,  # EVENT_STDERR
      undef,          # STATE_STDERR
    ], $type;

  # Wait here while the child sets itself up.
  close $sem_pipe_write;
  <$sem_pipe_read>;
  close $sem_pipe_read;

  $self->_define_stdin_flusher();
  $self->_define_stdout_reader() if defined $stdout_event;
  $self->_define_stderr_reader() if defined $stderr_event;

  return $self;
}

#------------------------------------------------------------------------------
# Define the internal state that will flush output to the child
# process' STDIN pipe.

sub _define_stdin_flusher {
  my $self = shift;

  # Read-only members.  If any of these change, then the write state
  # is invalidated and needs to be redefined.
  my $unique_id     = $self->[UNIQUE_ID];
  my $driver        = $self->[DRIVER];
  my $error_event   = \$self->[ERROR_EVENT];
  my $stdin_filter  = $self->[FILTER_STDIN];
  my $stdin_event   = \$self->[EVENT_STDIN];

  # Read/write members.  These are done by reference, to avoid pushing
  # $self into the anonymous sub.  Extra copies of $self are bad and
  # can prevent wheels from destructing properly.
  my $stdin_octets = \$self->[OCTETS_STDIN];

  # Register the select-write handler.
  $poe_kernel->state
    ( $self->[STATE_STDIN] = ref($self) . "($unique_id) -> select stdin",
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        $$stdin_octets = $driver->flush($handle);

        # When you can't write, nothing else matters.
        if ($!) {
          $$error_event && $k->call( $me, $$error_event,
                                     'write', ($!+0), $!, $unique_id
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
  if (defined $self->[EVENT_STDOUT]) {

    # If any of these change, then the read state is invalidated and
    # needs to be redefined.
    my $unique_id     = $self->[UNIQUE_ID];
    my $driver        = $self->[DRIVER];
    my $error_event   = \$self->[ERROR_EVENT];
    my $stdout_filter = $self->[FILTER_STDOUT];
    my $stdout_event  = \$self->[EVENT_STDOUT];

    $poe_kernel->state
      ( $self->[STATE_STDOUT] = ref($self) . "($unique_id) -> select stdout",
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
              $k->call( $me, $$error_event, 'read', ($!+0), $!, $unique_id );
            $k->select_read($handle);
          }
        }
      );

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
  if (defined $self->[EVENT_STDERR]) {
    # If any of these change, then the read state is invalidated and
    # needs to be redefined.
    my $unique_id     = $self->[UNIQUE_ID];
    my $driver        = $self->[DRIVER];
    my $error_event   = \$self->[ERROR_EVENT];
    my $stderr_filter = $self->[FILTER_STDERR];
    my $stderr_event  = \$self->[EVENT_STDERR];

    $poe_kernel->state
      ( $self->[STATE_STDERR] = ref($self) . "($unique_id) -> select stderr",
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
              $k->call( $me, $$error_event, 'read', ($!+0), $!, $unique_id );
            $k->select_read($handle);
          }
        }
      );

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
      $redefine_stdin = $redefine_stdout = $redefine_stderr = 1;
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
  if ( $self->[OCTETS_STDIN] =
       $self->[DRIVER]->put($self->[FILTER_STDIN]->put(\@chunks))
  ) {
    $poe_kernel->select_resume_write($self->[HANDLE_STDIN]);
  }

  # No watermark.
  return 0;
}

#------------------------------------------------------------------------------
# Redefine filters, one at a time or at once.  This is based on PG's
# code in Wheel::ReadWrite.

sub set_filter {
  croak "set_filter not implemented";
}

sub set_stdin_filter {
  croak "set_stdin_filter not implemented";
}

sub set_stdout_filter {
  croak "set_stdout_filter not implemented";
}

sub set_stderr_filter {
  croak "set_stderr_filter not implemented";
}

#------------------------------------------------------------------------------
# Data accessors.

sub get_driver_out_octets {
  $_[0]->[OCTETS_STDIN];
}

sub get_driver_out_messages {
  $_[0]->[DRIVER]->get_out_messages_buffered();
}

sub ID {
  $_[0]->[UNIQUE_ID];
}

sub PID {
  $_[0]->[CHILD_PID];
}

sub kill {
  my ($self, $signal) = @_;
  $signal = 'TERM' unless $signal;
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
    Program    => $program,
    Priority   => +5,                 # Adjust priority.  May need to be root.
    User       => getpwnam('nobody'), # Adjust UID. May need to be root.
    Group      => getgrnam('nobody'), # Adjust GID. May need to be root.
    ErrorEvent => 'oops',             # Event to emit on errors.

    StdinEvent  => 'stdin',  # Event to emit when stdin is flushed to child.
    StdoutEvent => 'stdout', # Event to emit with child stdout information.
    StderrEvent => 'stderr', # Event to emit with child stderr information.

    # Identify the child process' I/O type.
    Filter => POE::Filter::Line->new(), # Or some other filter.

    # May also specify filters per handle.
    StdinFilter  => POE::Filter::Line->new(),   # Child accepts input as lines.
    StdoutFilter => POE::Filter::Stream->new(), # Child output is a stream.
    StderrFilter => POE::Filter::Line->new(),   # Child errors are lines.
  );

  print "Unique wheel ID is  : ", $wheel->ID;
  print "Wheel's child PID is: ", $wheel->PID;

  # Send something to the child's STDIN.
  $wheel->put( 'input for the child' );

  # Kill the child.
  $wheel->kill();
  $wheel->kill( -9 );

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
process.  It may either be 'pipe' (the default), or 'pty'.

Pty conduits require the IO::Pty module.

=item ErrorEvent

=item StdinEvent

=item StdoutEvent

=item StderrEvent

C<ErrorEvent> contains the name of an event to emit if something
fails.  It's optional, and if omitted, it won't emit any errors.

Wheel::Run requires at least one of the following three events:

C<StdinEvent> contains the name of an event that Wheel::Run emits
whenever all its output has been flushed to the child process' STDIN
handle.

C<StdoutEvent> and C<StderrEvent> contain names of events that
Wheel::Run emits whenever the child process writes something to its
STDOUT or STDERR handles, respectively.

=item Filter

=item StdinFilter

=item StdoutFilter

=item StderrFilter

C<Filter> contains a reference to a POE::Filter class that describes
how the child process performs input and output.  C<Filter> will be
used to describe the child's stdin, stdout and stderr.

C<StdinFilter>, C<StdoutFilter> and C<StderrFilter> can be used
instead of C<Filter> to set different filters for each handle.

=item Group

C<Group> contains a numerical group ID that the child process should
run at.  This may not be meaningful on systems that have no concept of
group IDs.  The current process may need to run as root in order to
change group IDs.  Mileage varies considerably.

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

=item set_filter FILTER_REFERENCE

Set C<StdinFilter>, C<StdoutFilter>, and C<StderrFilter> all at once.
Not yet implemented.

=item set_stdin_filter FILTER_REFERENCE

Set C<StdinFilter> to something else.  Not yet implemented.

=item set_stdout_filter FILTER_REFERENCE

Set C<StdoutFilter> to something else.  Not yet implemented.

=item set_stderr_filter FILTER_REFERENCE

Set C<StderrFilter> to something else.  Not yet implemented.

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

=item kill

Sends a signal to the child process.  It's useful for processes which
tend to be reluctant to exit when their terminals are closed.

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item ErrorEvent

ErrorEvent contains the name on an event that Wheel::Run emits
whenever an error occurs.  Every error event comes with four
parameters:

C<ARG0> contains the name of the operation that failed.  It may be
'read' or 'write' or 'fork' or 'exec' or something.  The actual values
aren't yet defined.  Note: This is not necessarily a function name.

C<ARG1> and C<ARG2> hold numeric and string values for C<$!>,
respectively.

C<ARG3> contains the wheel's unique ID.

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

Wheel::Run generates SIGCHLD.  This may eventually cause Perl to
segfault.  Bleah.

Priority is a delta; there's no way to set it directly to some value.

User must be specified by UID.  It would be nice to support login
names.

Group must be specified by GID.  It would be nice to support group
names.

ActiveState Perl is not going to like this module one bit.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
