# $Id$

package POE::Wheel::FollowTail;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp;
use Symbol;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE qw(Wheel Driver::SysRW Filter::Line);
use IO::Handle;

sub CRIMSON_SCOPE_HACK ($) { 0 }

sub SELF_HANDLE      () {  0 }
sub SELF_FILENAME    () {  1 }
sub SELF_DRIVER      () {  2 }
sub SELF_FILTER      () {  3 }
sub SELF_INTERVAL    () {  4 }
sub SELF_EVENT_INPUT () {  5 }
sub SELF_EVENT_ERROR () {  6 }
sub SELF_EVENT_RESET () {  7 }
sub SELF_UNIQUE_ID   () {  8 }
sub SELF_STATE_READ  () {  9 }
sub SELF_LAST_STAT   () { 10 }
sub SELF_FOLLOW_MODE () { 11 }

sub MODE_TIMER  () { 0x01 } # Follow on a timer loop.
sub MODE_SELECT () { 0x02 } # Follow via select().

# Turn on tracing.  A lot of debugging occurred just after 0.11.
sub TRACE_RESET        () { 0 }
sub TRACE_STAT         () { 0 }
sub TRACE_STAT_VERBOSE () { 0 }
sub TRACE_POLL         () { 0 }

# Tk doesn't provide a SEEK method, as of 800.022
BEGIN {
  if (exists $INC{'Tk.pm'}) {
    eval <<'    EOE';
      sub Tk::Event::IO::SEEK {
        my $o = shift;
        $o->wait(Tk::Event::IO::READABLE);
        my $h = $o->handle;
        sysseek($h, shift, shift);
      }
    EOE
  }
}

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel" unless (defined $poe_kernel);

  # STATE-EVENT
  if (exists $params{InputState}) {
    croak "InputState is deprecated.  Use InputEvent";
  }

  # STATE-EVENT
  if (exists $params{ErrorState}) {
    croak "ErrorState is deprecated.  Use ErrorEvent";
  }

  croak "FollowTail requires a Handle or Filename parameter, but not both"
    unless $params{Handle} xor defined $params{Filename};

  my $driver = delete $params{Driver};
  $driver = POE::Driver::SysRW->new() unless defined $driver;

  my $filter = delete $params{Filter};
  $filter = POE::Filter::Line->new() unless defined $filter;

  croak "InputEvent required" unless defined $params{InputEvent};

  my $handle   = $params{Handle};
  my $filename = $params{Filename};

  my @start_stat;
  if (defined $filename) {
    $handle = gensym();

    # FIFOs (named pipes) are opened R/W so they don't report EOF.
    if (-p $filename) {
      open $handle, "+<$filename" or
        croak "can't open fifo $filename for R/W: $!";
    }

    # Everything else is opened read-only.
    else {
      open $handle, "<$filename" or croak "can't open $filename: $!";
    }
    @start_stat = stat($filename);
  }

  my $poll_interval = $params{PollInterval} || 1;
  my $seek_back     = $params{SeekBack} || 4096;
  $seek_back = 0 if $seek_back < 0;

  my $self = bless
    [ $handle,                          # SELF_HANDLE
      $filename,                        # SELF_FILENAME
      $driver,                          # SELF_DRIVER
      $filter,                          # SELF_FILTER
      $poll_interval,                   # SELF_INTERVAL
      delete $params{InputEvent},       # SELF_EVENT_INPUT
      delete $params{ErrorEvent},       # SELF_EVENT_ERROR
      delete $params{ResetEvent},       # SELF_EVENT_RESET
      &POE::Wheel::allocate_wheel_id(), # SELF_UNIQUE_ID
      undef,                            # SELF_STATE_READ
      \@start_stat,                     # SELF_LAST_STAT
      undef,                            # SELF_FOLLOW_MODE
    ], $type;

  # SeekBack and partial-input discarding only work for plain files.
  # SeekBack attempts to position the file pointer somewhere before
  # the end of the file.  If it's specified, we assume the user knows
  # where a record begins.  Otherwise we just seek back and discard
  # everything to EOF so we can frame the input record.

  if (-f $handle) {
    my $end = sysseek($handle, 0, SEEK_END);
    if (defined($end) and ($end < $seek_back)) {
      sysseek($handle, 0, SEEK_SET);
    }
    else {
      sysseek($handle, -$seek_back, SEEK_END);
    }

    # Discard partial input chunks unless a SeekBack was specified.
    unless (defined $params{SeekBack}) {
      while (defined(my $raw_input = $driver->get($handle))) {
        # Skip out if there's no more input.
        last unless @$raw_input;
        $filter->get($raw_input);
      }
    }

    # Start the timer loop.
    $self->[SELF_FOLLOW_MODE] = MODE_TIMER;
    $self->_define_timer_states();
  }

  # Strange things that ought not be tailed?  Directories...
  elsif (-d $handle) {
    croak "FollowTail does not accept directories";
  }

  # Otherwise it's not a plain file.  We won't honor SeekBack, and we
  # will use select_read to watch the handle.
  else {
    carp "FollowTail does not support SeekBack on a special file"
      if defined $params{SeekBack};
    carp "FollowTail does not use PollInterval for special files"
      if defined $params{PollInterval};

    # Start the select loop.
    $self->[SELF_FOLLOW_MODE] = MODE_SELECT;
    $self->_define_select_states();
  }

  return $self;
}

### Define the select based polling loop.  This relies on stupid
### closure tricks to keep references to $self out of anonymous
### coderefs.  Otherwise a circular reference would occur, and the
### wheel would never self-destruct.

sub _define_select_states {
  my $self = shift;

  my $filter      = $self->[SELF_FILTER];
  my $driver      = $self->[SELF_DRIVER];
  my $handle      = $self->[SELF_HANDLE];
  my $unique_id   = $self->[SELF_UNIQUE_ID];
  my $event_input = \$self->[SELF_EVENT_INPUT];
  my $event_error = \$self->[SELF_EVENT_ERROR];
  my $event_reset = \$self->[SELF_EVENT_RESET];

  TRACE_POLL and warn "defining select state";

  $poe_kernel->state
    ( $self->[SELF_STATE_READ] = ref($self) . "($unique_id) -> select read",
      sub {

        # Protects against coredump on older perls.
        0 && CRIMSON_SCOPE_HACK('<');

        # The actual code starts here.
        my ($k, $ses) = @_[KERNEL, SESSION];

        eval {
          sysseek($handle, 0, SEEK_CUR);
        };
        $! = 0;

        TRACE_POLL and warn time . " read ok";

        if (defined(my $raw_input = $driver->get($handle))) {
          if (@$raw_input) {
            TRACE_POLL and warn time . " raw input";
            foreach my $cooked_input (@{$filter->get($raw_input)}) {
              TRACE_POLL and warn time . " cooked input";
              $k->call($ses, $$event_input, $cooked_input, $unique_id);
            }
          }
        }

        # Error reading.  Report the error if it's not EOF, or if it's
        # EOF on a socket or TTY.  Shut down the select, too.
        else {
          if ($! or (-S $handle) or (-t $handle)) {
            TRACE_POLL and warn time . " error: $!";
            $$event_error and
              $k->call($ses, $$event_error, 'read', ($!+0), $!, $unique_id);
            $k->select($handle);
          }
          eval { IO::Handle::clearerr($handle) }; # could be a globref
        }
      }
    );

  $poe_kernel->select_read($handle, $self->[SELF_STATE_READ]);
}

### Define the timer based polling loop.  This also relies on stupid
### closure tricks.

sub _define_timer_states {
  my $self = shift;

  my $filter        = $self->[SELF_FILTER];
  my $driver        = $self->[SELF_DRIVER];
  my $unique_id     = $self->[SELF_UNIQUE_ID];
  my $poll_interval = $self->[SELF_INTERVAL];
  my $filename      = $self->[SELF_FILENAME];
  my $last_stat     = $self->[SELF_LAST_STAT];
  my $handle        = $self->[SELF_HANDLE];
  my $state_read    = $self->[SELF_STATE_READ] =
    ref($self) . "($unique_id) -> timer read";

  my $event_input   = \$self->[SELF_EVENT_INPUT];
  my $event_error   = \$self->[SELF_EVENT_ERROR];
  my $event_reset   = \$self->[SELF_EVENT_RESET];

  TRACE_POLL and warn "defining timer state";

  $poe_kernel->state
    ( $state_read,
      sub {

        # Protects against coredump on older perls.
        0 && CRIMSON_SCOPE_HACK('<');

        # The actual code starts here.
        my ($k, $ses) = @_[KERNEL, SESSION];

        eval {
          if (defined $filename) {
            my @new_stat = stat($filename);

            TRACE_STAT_VERBOSE and do {
              my @test_new = @new_stat;   splice(@test_new, 8, 1, "(removed)");
              my @test_old = @$last_stat; splice(@test_old, 8, 1, "(removed)");
              warn "=== @test_new" if "@test_new" ne "@test_old";
            };

            if (@new_stat) {

              # File shrank.  Consider it a reset.
              if ($new_stat[7] < $last_stat->[7]) {
                $$event_reset and $k->call($ses, $$event_reset, $unique_id);
                $last_stat->[7] = $new_stat[7];
              }

              # Something fundamental about the file changed.  Reopen it.
              if ( $new_stat[1] != $last_stat->[1] or # inode's number
                   $new_stat[0] != $last_stat->[0] or # inode's device
                   $new_stat[6] != $last_stat->[6] or # device type
                   $new_stat[3] != $last_stat->[3]    # number of links
                 ) {

                TRACE_STAT and do {
                  warn "inode $new_stat[1] != old $last_stat->[1]\n"
                    if $new_stat[1] != $last_stat->[1];
                  warn "inode device $new_stat[0] != old $last_stat->[0]\n"
                    if $new_stat[0] != $last_stat->[0];
                  warn "device type $new_stat[6] != old $last_stat->[6]\n"
                    if $new_stat[6] != $last_stat->[6];
                  warn "number of links $new_stat[3] != old $last_stat->[3]\n"
                    if $new_stat[3] != $last_stat->[3];
                  warn "file size $new_stat[7] < old $last_stat->[7]\n"
                    if $new_stat[7] < $last_stat->[7];
                };

                @$last_stat = @new_stat;

                close $handle;
                unless (open $handle, "<$filename") {
                  $$event_error and
                    $k->call( $ses, $$event_error, 'reopen',
                              ($!+0), $!, $unique_id
                            );
                }
              }
            }
          }
        };
        $! = 0;

        TRACE_POLL and warn time . " read ok\n";

        # Got input.  Read a bunch of it, then poll again right away.
        if (defined(my $raw_input = $driver->get($handle))) {
          if (@$raw_input) {
            TRACE_POLL and warn time . " raw input\n";
            foreach my $cooked_input (@{$filter->get($raw_input)}) {
              TRACE_POLL and warn time . " cooked input\n";
              $k->call($ses, $$event_input, $cooked_input, $unique_id);
            }
          }
          $k->yield($state_read);
        }

        # Got an error of some sort.
        else {
          TRACE_POLL and warn time . " set delay\n";
          if ($!) {
            TRACE_POLL and warn time . " error: $!\n";
            $$event_error and
              $k->call($ses, $$event_error, 'read', ($!+0), $!, $unique_id);
            $k->select($handle);
          }
          $k->delay($state_read, $poll_interval);
          IO::Handle::clearerr($handle);
        }
      }
    );

  $poe_kernel->yield($state_read);
}

# ### Define the select states, and begin reading the special handle.
# ### This also relies on stupid closure tricks.

#     $poe_kernel->select($handle, $self->[SELF_STATE_READ]);

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    # STATE-EVENT
    if ($name =~ /^(.*?)State$/) {
      croak "$name is deprecated.  Use $1Event";
    }

    if ($name eq 'InputEvent') {
      if (defined $event) {
        $self->[SELF_EVENT_INPUT] = $event;
      }
      else {
        carp "InputEvent requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorEvent') {
      $self->[SELF_EVENT_ERROR] = $event;
    }
    elsif ($name eq 'ResetEvent') {
      $self->[SELF_EVENT_RESET] = $event;
    }
    else {
      carp "ignoring unknown FollowTail parameter '$name'";
    }
  }

  if ($self->[SELF_FOLLOW_MODE] & MODE_TIMER) {
    $self->_define_timer_states();
  }
  elsif ($self->[SELF_FOLLOW_MODE] & MODE_SELECT) {
    $self->_define_select_states();
  }
  else {
    die;
  }
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  # Remove our tentacles from our owner.
  $poe_kernel->select($self->[SELF_HANDLE]);
  $poe_kernel->delay($self->[SELF_STATE_READ]);

  if ($self->[SELF_STATE_READ]) {
    $poe_kernel->state($self->[SELF_STATE_READ]);
    undef $self->[SELF_STATE_READ];
  }

  &POE::Wheel::free_wheel_id($self->[SELF_UNIQUE_ID]);
}

#------------------------------------------------------------------------------

sub ID {
  return $_[0]->[SELF_UNIQUE_ID];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::FollowTail - follow the tail of an ever-growing file

=head1 SYNOPSIS

  $wheel = POE::Wheel::FollowTail->new(
    Filename     => $file_name,                    # File to tail
    Driver       => POE::Driver::Something->new(), # How to read it
    Filter       => POE::Filter::Something->new(), # How to parse it
    PollInterval => 1,                  # How often to check it
    InputEvent   => $input_event_name,  # Event to emit upon input
    ErrorEvent   => $error_event_name,  # Event to emit upon error
    ResetEvent   => $reset_event_name,  # Event to emit on file reset
    SeekBack     => $offset,            # How far from EOF to start
  );

  $wheel = POE::Wheel::FollowTail->new(
    Handle       => $open_file_handle,             # File to tail
    Driver       => POE::Driver::Something->new(), # How to read it
    Filter       => POE::Filter::Something->new(), # How to parse it
    PollInterval => 1,                  # How often to check it
    InputEvent   => $input_event_name,  # Event to emit upon input
    ErrorEvent   => $error_event_name,  # Event to emit upon error
    # No reset event available.
    SeekBack     => $offset,            # How far from EOF to start
  );

=head1 DESCRIPTION

FollowTail follows the end of an ever-growing file, such as a log of
system events.  It generates events for each new record that is
appended to its file.

This is a read-only wheel so it does not include a put() method.

=head1 PUBLIC METHODS

=over 2

=item event EVENT_TYPE => EVENT_NAME, ...

event() is covered in the POE::Wheel manpage.

FollowTail's event types are C<InputEvent>, C<ResetEvent>, and
C<ErrorEvent>.

=item ID

The ID method returns a FollowTail wheel's unique ID.  This ID will be
included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item Driver

Driver is a POE::Driver subclass that is used to read from and write
to FollowTail's filehandle.  It encapsulates the low-level I/O
operations needed to access a file so in theory FollowTail never needs
to know about them.

POE::Wheel::FollowTail uses POE::Driver::SysRW if one is not
specified.

=item Filter

Filter is a POE::Filter subclass that is used to parse input from the
tailed file.  It encapsulates the lowest level of a protocol so that
in theory FollowTail never needs to know about file formats.

POE::Wheel::FollowTail uses POE::Filter::Line if one is not
specified.

=item PollInterval

PollInterval is the amount of time, in seconds, the wheel will wait
before retrying after it has reached the end of the file.  This delay
prevents the wheel from going into a CPU-sucking loop.

=item SeekBack

The SeekBack parameter tells FollowTail how far before EOF to start
reading before following the file.  Its value is specified in bytes,
and values greater than the file's current size will quietly cause
FollowTail to start from the file's beginning.

When SeekBack isn't specified, the wheel seeks 4096 bytes before the
end of the file and discards everything it reads up until EOF.  It
does this to frame records within the file.

When SeekBack is used, the wheel assumes that records have already
been framed, and the seek position is the beginning of one.  It will
return everything it reads up until EOF.

=item Handle

=item Filename

Either the Handle or Filename constructor parameter is required, but
you cannot supply both.

FollowTail can watch a file or device that's already open.  Give it
the open filehandle with its Handle parameter.

FollowTail can watch a file by name, given as the Filename parameter.

This wheel can detect files that have been "reset".  That is, it can
tell when log files have been restarted due to a rotation or purge.
For FollowTail to do this, though, it requires a Filename parameter.
This is so FollowTail can reopen the file after it has reset.  See
C<ResetEvent> elsewhere in this document.

=item InputEvent

InputEvent contains the name of an event which is emitted for every
complete record read.  Every InputEvent event is accompanied by two
parameters.  C<ARG0> contains the record which was read.  C<ARG1>
contains the wheel's unique ID.

A sample InputEvent event handler:

  sub input_state {
    my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
    print "Wheel $wheel_id received input: $input\n";
  }

=item ResetEvent

ResetEvent contains the name of an event that's emitted every time a
file is reset.

It's only available when watching files by name.  This is because
FollowTail must reopen the file after it has been reset.

C<ARG0> contains the FollowTail wheel's unique ID.

=item ErrorEvent

ErrorEvent contains the event which is emitted whenever an error
occurs.  Every ErrorEvent comes with four parameters:

C<ARG0> contains the name of the operation that failed.  This usually
is 'read'.  Note: This is not necessarily a function name.  The wheel
doesn't know which function its Driver is using.

C<ARG1> and C<ARG2> hold numeric and string values for C<$!>,
respectively.  Note: FollowTail knows how to handle EAGAIN, so it will
never return that error.

C<ARG3> contains the wheel's unique ID.

A sample ErrorEvent event handler:

  sub error_state {
    my ($operation, $errnum, $errstr, $wheel_id) = @_[ARG0..ARG3];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
  }

=back

=head1 SEE ALSO

POE::Wheel.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

This wheel can't tail pipes and consoles on some systems.

Because this wheel is cooperatively multitasked, it may lose records
just prior to a file reset.  For a more robust way to watch files,
consider using POE::Wheel::Run and your operating system's native
"tail" utility instead.

  $heap->{tail} = POE::Wheel::Run->new
    ( Program     => [ "/usr/bin/tail", "-f", $file_name ],
      StdoutEvent => "log_record",
    );

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
