# $Id$

package POE::Wheel::FollowTail;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp;
use Symbol;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE qw(Wheel Driver::SysRW Filter::Line);

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
sub SELF_STATE_WAKE  () { 10 }
sub SELF_LAST_STAT   () { 11 }

# Turn on tracing.  A lot of debugging occurred just after 0.11.
sub TRACE () { 0 }

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

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  # STATE-EVENT
  if (exists $params{InputState}) {
    carp "InputState is deprecated.  Use InputEvent";
    if (exists $params{InputEvent}) {
      delete $params{InputState};
    }
    else {
      $params{InputEvent} = delete $params{InputState};
    }
  }

  # STATE-EVENT
  if (exists $params{ErrorState}) {
    carp "ErrorState is deprecated.  Use ErrorEvent";
    if (exists $params{ErrorEvent}) {
      delete $params{ErrorState};
    }
    else {
      $params{ErrorEvent} = delete $params{ErrorState};
    }
  }

  croak "Handle or Filename required, but not both"
    unless $params{Handle} xor defined $params{Filename};

  my $driver = delete $params{Driver};
  $driver = POE::Driver::SysRW->new() unless defined $driver;

  my $filter = delete $params{Filter};
  $filter = POE::Filter::Line->new() unless defined $filter;

  croak "InputEvent required" unless defined $params{InputEvent};

  my ($handle, $filename) = @params{ qw(Handle Filename) };

  my @start_stat;
  if (defined $filename) {
    $handle = gensym();
    open $handle, "<$filename" or croak "can't open $filename: $!";
    @start_stat = stat($filename);
  }

  my $poll_interval = ( (defined $params{PollInterval})
                        ? $params{PollInterval}
                        : 1
                      );

  my $seek_back = ( (defined $params{SeekBack})
                    ? $params{SeekBack}
                    : 4096
                  );
  $seek_back = 0 if $seek_back < 0;

  my $self = bless [ $handle,                          # SELF_HANDLE
                     $filename,                        # SELF_FILENAME
                     $driver,                          # SELF_DRIVER
                     $filter,                          # SELF_FILTER
                     $poll_interval,                   # SELF_INTERVAL
                     delete $params{InputEvent},       # SELF_EVENT_INPUT
                     delete $params{ErrorEvent},       # SELF_EVENT_ERROR
                     delete $params{ResetEvent},       # SELF_EVENT_RESET
                     &POE::Wheel::allocate_wheel_id(), # SELF_UNIQUE_ID
                     undef,                            # SELF_STATE_READ
                     undef,                            # SELF_STATE_WAKE
                     \@start_stat,                     # SELF_LAST_STAT
                  ], $type;

  $self->_define_states();

  # Nudge the wheel into action before performing initial operations
  # on it.  Part of the Kernel's select() logic is making things
  # non-blocking, and the following code will assume that.

  $poe_kernel->select($handle, $self->[SELF_STATE_READ]);

  # Try to position the file pointer before the end of the file.  This
  # is so we can "tail -f" an existing file.  FreeBSD, at least,
  # allows sysseek to go before the beginning of a file.  Trouble
  # ensues at that point, causing the file never to be read again.
  # This code does some extra work to prevent seeking beyond the start
  # of a file.

  eval {
    my $end = sysseek($handle, 0, SEEK_END);
    if (defined($end) and ($end < $seek_back)) {
      sysseek($handle, 0, SEEK_SET);
    }
    else {
      sysseek($handle, -$seek_back, SEEK_END);
    }
  };

  # Discard partial input chunks unless a SeekBack was specified.
  unless (defined $params{SeekBack}) {
    while (defined(my $raw_input = $driver->get($handle))) {
      # Skip out if there's no more input.
      last unless @$raw_input;
      $filter->get($raw_input);
    }
  }

  return $self;
}

#------------------------------------------------------------------------------
# This relies on stupid closure tricks to keep references to $self out
# of anonymous coderefs.  Otherwise, the wheel won't disappear when a
# state deletes it.

sub _define_states {
  my $self = shift;

  # If any of these change, then the states are invalidated and must
  # be redefined.

  my $filter        = $self->[SELF_FILTER];
  my $driver        = $self->[SELF_DRIVER];
  my $event_input   = \$self->[SELF_EVENT_INPUT];
  my $event_error   = \$self->[SELF_EVENT_ERROR];
  my $event_reset   = \$self->[SELF_EVENT_RESET];
  my $unique_id     = $self->[SELF_UNIQUE_ID];
  my $state_wake    = $self->[SELF_STATE_WAKE] =
    ref($self) . "($unique_id) -> alarm";
  my $state_read    = $self->[SELF_STATE_READ] =
    ref($self) . "($unique_id) -> select read";
  my $poll_interval = $self->[SELF_INTERVAL];
  my $filename      = $self->[SELF_FILENAME];
  my $last_stat     = $self->[SELF_LAST_STAT];
  my $handle        = $self->[SELF_HANDLE];

  # Define the read state.

  TRACE and do { warn $state_read; };

  $poe_kernel->state
    ( $state_read,
      sub {

        # Protects against coredump on older perls.
        0 && CRIMSON_SCOPE_HACK('<');

        # The actual code starts here.
        my ($k, $ses) = @_[KERNEL, SESSION];

        $k->select_read($handle);

        eval {
          if (defined $filename) {
            my @new_stat = stat($filename);
            # warn "@new_stat\n";
            if (@new_stat) {
              if ( $new_stat[1] != $last_stat->[1] or # inode's number
                   $new_stat[0] != $last_stat->[0] or # inode's device
                   $new_stat[6] != $last_stat->[6] or # device type
                   $new_stat[7] <  $last_stat->[7]    # file shrunk
                 ) {

                TRACE and do {
                  warn "inode $new_stat[1] != old $last_stat->[1]\n"
                    if $new_stat[1] != $last_stat->[1];
                  warn "inode device $new_stat[0] != old $last_stat->[0]\n"
                    if $new_stat[0] != $last_stat->[0];
                  warn "device type $new_stat[6] != old $last_stat->[6]\n"
                    if $new_stat[6] != $last_stat->[6];
                  warn "file size $new_stat[7] < old $last_stat->[7]\n"
                    if $new_stat[7] < $last_stat->[7];
                };

                close $handle;
                if (open $handle, "<$filename") {
                  @$last_stat = @new_stat;
                  $$event_reset and $k->call( $ses,
                                              $$event_reset, $unique_id
                                            );
                }
                else {
                  $$event_error and
                    $k->call( $ses, $$event_error, 'reopen',
                              ($!+0), $!, $unique_id
                            );
                }
              }
              else {
                sysseek($handle, 0, SEEK_CUR);
              }
            }
          }
          else {
            sysseek($handle, 0, SEEK_CUR);
          }
        };
        $! = 0;

        TRACE and do { warn time . " read ok\n"; };

        if (defined(my $raw_input = $driver->get($handle))) {
          TRACE and do { warn time . " raw input\n"; };
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            TRACE and do { warn time . " cooked input\n"; };
            $k->call($ses, $$event_input, $cooked_input, $unique_id);
          }
        }

        if ($!) {
          TRACE and do { warn time . " error: $!\n"; };
          $$event_error and
            $k->call($ses, $$event_error, 'read', ($!+0), $!, $unique_id);
        }

        TRACE and do { warn time . " set delay\n"; };
        $k->delay($state_wake, $poll_interval);
      }
    );

  # Define the alarm state that periodically wakes the wheel and
  # retries to read from the file.

  TRACE and do { warn $state_wake; };

  $poe_kernel->state
    ( $state_wake,
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my $k = $_[KERNEL];

        TRACE and do { warn time . " wake up and select the handle\n"; };

        $k->select_read($handle, $state_read);
      }
    );
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    # STATE-EVENT
    if ($name =~ /^(.*?)State$/) {
      carp "$name is deprecated.  Use $1Event";
      $name = $1 . 'Event';
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

  $self->_define_states();
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->[SELF_HANDLE]);

  if ($self->[SELF_STATE_READ]) {
    $poe_kernel->state($self->[SELF_STATE_READ]);
    undef $self->[SELF_STATE_READ];
  }

  if ($self->[SELF_STATE_WAKE]) {
    $poe_kernel->state($self->[SELF_STATE_WAKE]);
    undef $self->[SELF_STATE_WAKE];
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

=item Filter

Filter is a POE::Filter subclass that is used to parse input from the
tailed file.  It encapsulates the lowest level of a protocol so that
in theory FollowTail never needs to know about file formats.

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

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
