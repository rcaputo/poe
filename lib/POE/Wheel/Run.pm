# $Id$

# -><- error operations need to be better

package POE::Wheel::Run;

use strict;
use Carp;
use POE qw(Wheel Pipe::Unidirectional Driver::SysRW);

# Offsets into $self.
sub UNIQUE_ID     () {  0 }
sub DRIVER        () {  1 }
sub ERROR_EVENT   () {  2 }
sub PROGRAM       () {  3 }
sub CHILD_PID     () {  4 }

sub HANDLE_STDIN  () {  5 }
sub FILTER_STDIN  () {  6 }
sub EVENT_STDIN   () {  7 }
sub STATE_STDIN   () {  8 }
sub OCTETS_STDIN  () {  9 }

sub HANDLE_STDOUT () { 10 }
sub FILTER_STDOUT () { 11 }
sub EVENT_STDOUT  () { 12 }
sub STATE_STDOUT  () { 13 }

sub HANDLE_STDERR () { 14 }
sub FILTER_STDERR () { 15 }
sub EVENT_STDERR  () { 16 }
sub STATE_STDERR  () { 17 }

# Used to work around a bug in older perl versions.
sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
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

  my $stdin_event  = delete $params{StdinEvent};
  my $stdout_event = delete $params{StdoutEvent};
  my $stderr_event = delete $params{StderrEvent};

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
  $stderr_filter = $all_filter unless defined $stderr_filter;

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

  # Make the pipes.  We make more pipes than strictly necessary in
  # case someone wants to turn some onn later.
  my ($stdin_read,  $stdin_write)  = POE::Pipe::Unidirectional->new();
  croak "could not make stdin pipes: $!"
    unless defined $stdin_read and defined $stdin_write;

  my ($stdout_read, $stdout_write) = POE::Pipe::Unidirectional->new();
  croak "could not make stdout pipes: $!"
    unless defined $stdout_read and defined $stdout_write;

  my ($stderr_read, $stderr_write) = POE::Pipe::Unidirectional->new();
  croak "could not make stderr pipes: $!"
    unless defined $stderr_read and defined $stderr_write;

  # Fork!  Woo-hoo!
  my $pid = fork;

  # Child.  Parent side continues after this block.
  unless ($pid) {
    croak "couldn't fork: $!" unless defined $pid;

    # Redirect STDIN from the read end of the stdin pipe.
    open( STDIN, "<&=" . fileno($stdin_read) )
      or die "can't redirect STDIN in child pid $$: $!";

    # Redirect STDOUT to the write end of the stdout pipe.
    open( STDOUT, ">&=" . fileno($stdout_write) )
      or die "can't redirect stdout in child pid $$: $!";

    # Redirect STDERR to the write end of the stderr pipe.
    open( STDERR, ">&=" . fileno($stderr_write) )
      or die "can't redirect stderr in child: $!";

    # Fix the priority delta.  -><- Hardcoded constants mean this
    # process, at least here.  [crosses fingers] -><- Also must add
    # failure events for this.  -><- Also must wrap it in eval for
    # systems where it's not supported.  -><- Warn if new priority is
    # <0 and not superuser.
    my $priority = getpriority(0, $$);
    if (defined $priority) {
      setpriority(0, $$, $priority + $priority_delta);
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

    # Exec the program depending on its form.
    if (ref($program) eq 'ARRAY') {
      exec(@$program) or die "can't exec (@$program) in child pid $$: $!";
    }
    else {
      exec($program) or die "can't exec ($program) in child pid $$: $!";
    }
  }

  # Parent here.

  my $self = bless
    [ &POE::Wheel::allocate_wheel_id(),  # UNIQUE_ID
      POE::Driver::SysRW->new(),         # DRIVER
      $error_event,   # ERROR_EVENT
      $program,       # PROGRAM
      $pid,           # CHILD_PID
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

  $self->_define_stdin_flusher() if defined $stdin_event;
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
    ( $self->[STATE_STDIN] = $self . ' select stdin',
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
      ( $self->[STATE_STDOUT] = $self . ' select stdout',
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
      ( $self->[STATE_STDERR] = $self . ' select stderr',
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
      $self->[EVENT_STDERR] = $event;
      $redefine_stderr = 1;
    }
    elsif ($name eq 'ErrorEvent') {
      $self->[ERROR_EVENT] = $event;
      $redefine_stdin = $redefine_stdout = $redefine_stderr = 1;
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
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
  $poe_kernel->select($self->[HANDLE_STDIN]);
  if ($self->[STATE_STDIN]) {
    $poe_kernel->state($self->[STATE_STDIN]);
    $self->[STATE_STDIN] = undef;
  }

  $poe_kernel->select($self->[HANDLE_STDOUT]);
  if ($self->[STATE_STDOUT]) {
    $poe_kernel->state($self->[STATE_STDOUT]);
    $self->[STATE_STDOUT] = undef;
  }

  $poe_kernel->select($self->[HANDLE_STDERR]);
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
}

sub set_stdin_filter {
}

sub set_stdout_filter {
}

sub set_stderr_filter {
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

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::Run - event driven fork/exec with added value

=head1 SYNOPSIS

  $wheel = POE::Wheel::Run->new(

    # -><- code
  );

  # -><- code

=head1 DESCRIPTION

Wheel::Run spawns child processes and establishes non-blocking, event
based communication with them.

=head1 PUBLIC METHODS

=over 2

=item new LOTS_OF_STUFF

-><- code etc

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item StdinEvent

-><- code etc

=back

=head1 SEE ALSO

POE::Wheel.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

None currently known.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
