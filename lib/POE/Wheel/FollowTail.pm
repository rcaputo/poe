# $Id$

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE qw(Wheel);

sub CRIMSON_SCOPE_HACK ($) { 0 }

sub SELF_HANDLE      () { 0 }
sub SELF_DRIVER      () { 1 }
sub SELF_FILTER      () { 2 }
sub SELF_INTERVAL    () { 3 }
sub SELF_EVENT_INPUT () { 4 }
sub SELF_EVENT_ERROR () { 5 }
sub SELF_UNIQUE_ID   () { 6 }
sub SELF_STATE_READ  () { 7 }
sub SELF_STATE_WAKE  () { 8 }

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

  croak "Handle required"     unless defined $params{Handle};
  croak "Driver required"     unless defined $params{Driver};
  croak "Filter required"     unless defined $params{Filter};
  croak "InputState required" unless defined$params{InputState};

  my ($handle, $driver, $filter) = @params{ qw(Handle Driver Filter) };

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
                     $driver,                          # SELF_DRIVER
                     $filter,                          # SELF_FILTER
                     $poll_interval,                   # SELF_INTERVAL
                     $params{InputState},              # SELF_EVENT_INPUT
                     $params{ErrorEvent},              # SELF_EVENT_ERROR
                     &POE::Wheel::allocate_wheel_id(), # SELF_UNIQUE_ID
                     undef,                            # SELF_STATE_READ
                     undef,                            # SELF_STATE_WAKE
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
  my $state_wake    = $self->[SELF_STATE_WAKE] = $self . ' alarm';
  my $state_read    = $self->[SELF_STATE_READ] = $self . ' select read';
  my $poll_interval = $self->[SELF_INTERVAL];
  my $handle        = $self->[SELF_HANDLE];
  my $unique_id     = $self->[SELF_UNIQUE_ID];

  # Define the read state.

  TRACE and do { warn $state_read; };

  $poe_kernel->state
    ( $state_read,
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $ses, $hdl) = @_[KERNEL, SESSION, ARG0];

        $k->select_read($hdl);

        eval { sysseek($hdl, 0, SEEK_CUR); };
        $! = 0;

        TRACE and do { warn time . " read ok\n"; };

        if (defined(my $raw_input = $driver->get($hdl))) {
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

    if ($name eq 'InputState') {
      if (defined $event) {
        $self->[SELF_EVENT_INPUT] = $event;
      }
      else {
        carp "InputState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->[SELF_EVENT_ERROR] = $event;
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
    Handle       => $file_handle,                  # File to tail
    Driver       => POE::Driver::Something->new(), # How to read it
    Filter       => POE::Filter::Something->new(), # How to parse it
    PollInterval => 1,                  # How often to check it
    InputState   => $input_event_name,  # State to call upon input
    ErrorState   => $error_event_name,  # State to call upon error
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

FollowTail's event types are C<InputState> and C<ErrorState>.

=item ID

The ID method returns a FollowTail wheel's unique ID.  This ID will be
included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=back

=head1 EVENTS AND PARAMETERS

=over 2

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

=item InputState

InputState contains the event which is emitted for every complete
record read.  Every InputState event is accompanied by two parameters.
C<ARG0> contains the record which was read.  C<ARG1> contains the
wheel's unique ID.

A sample InputState event handler:

  sub input_state {
    my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
    print "Wheel $wheel_id received input: $input\n";
  }

=item ErrorState

ErrorState contains the event which is emitted whenever an error
occurs.  Every ErrorState event comes with four parameters:

C<ARG0> contains the name of the operation that failed.  This usually
is 'read'.  Note: This is not necessarily a function name.  The wheel
doesn't know which function its Driver is using.

C<ARG1> and C<ARG2> hold numeric and string values for C<$!>,
respectively.  Note: FollowTail knows how to handle EAGAIN, so it will
never return that error.

C<ARG3> contains the wheel's unique ID.

A sample ErrorState event handler:

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
