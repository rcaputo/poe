# $Id$

package POE::Wheel::ReadWrite;

use strict;
use Carp;
use POE qw(Wheel);

# Offsets into $self.
sub HANDLE_INPUT               () {  0 }
sub HANDLE_OUTPUT              () {  1 }
sub FILTER_INPUT               () {  2 }
sub FILTER_OUTPUT              () {  3 }
sub DRIVER_BOTH                () {  4 }
sub EVENT_INPUT                () {  5 }
sub EVENT_ERROR                () {  6 }
sub EVENT_FLUSHED              () {  7 }
sub WATERMARK_MARK_HIGH        () {  8 }
sub WATERMARK_MARK_LOW         () {  9 }
sub WATERMARK_EVENT_HIGH       () { 10 }
sub WATERMARK_EVENT_LOW        () { 11 }
sub WATERMARK_STATE            () { 12 }
sub DRIVER_BUFFERED_OUT_OCTETS () { 13 }
sub STATE_WRITE                () { 14 }
sub STATE_READ                 () { 15 }
sub UNIQUE_ID                  () { 16 }

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel" unless defined $poe_kernel;

  my ($in_handle, $out_handle);
  if (defined $params{Handle}) {
    carp "Ignoring InputHandle parameter (Handle parameter takes precedence)"
      if defined $params{InputHandle};
    carp "Ignoring OutputHandle parameter (Handle parameter takes precedence)"
      if defined $params{OutputHandle};
    $in_handle = $out_handle = delete $params{Handle};
  }
  else {
    croak "Handle or InputHandle required"
      unless defined $params{InputHandle};
    croak "Handle or OutputHandle required"
      unless defined $params{OutputHandle};
    $in_handle  = delete $params{InputHandle};
    $out_handle = delete $params{OutputHandle};
  }

  my ($in_filter, $out_filter);
  if (defined $params{Filter}) {
    carp "Ignoring InputFilter parameter (Filter parameter takes precedence)"
      if (defined $params{InputFilter});
    carp "Ignoring OUtputFilter parameter (Filter parameter takes precedence)"
      if (defined $params{OutputFilter});
    $in_filter = $out_filter = delete $params{Filter};
  }
  else {
    croak "Filter or InputFilter required"
      unless defined $params{InputFilter};
    croak "Filter or OutputFilter required"
      unless defined $params{OutputFilter};
    $in_filter  = delete $params{InputFilter};
    $out_filter = delete $params{OutputFilter};
  }

  croak "Driver required" unless defined $params{Driver};

  { my $mark_errors = 0;
    if (defined($params{HighMark}) xor defined($params{LowMark})) {
      carp "HighMark and LowMark parameters require each-other";
      $mark_errors++;
    }
    # Then they both exist, and they must be checked.
    elsif (defined $params{HighMark}) {
      unless (defined($params{HighMark}) and defined($params{LowMark})) {
        carp "HighMark and LowMark parameters must be defined";
        $mark_errors++;
      }
      unless (($params{HighMark} > 0) and ($params{LowMark} > 0)) {
        carp "HighMark and LowMark parameters must above 0";
        $mark_errors++;
      }
    }
    if (defined($params{HighMark}) xor defined($params{HighState})) {
      carp "HighMark and HighState parameters require each-other";
      $mark_errors++;
    }
    if (defined($params{LowMark}) xor defined($params{LowState})) {
      carp "LowMark and LowState parameters require each-other";
      $mark_errors++;
    }
    croak "Water mark errors" if $mark_errors;
  }

  my $self = bless
    [ $in_handle,                       # HANDLE_INPUT
      $out_handle,                      # HANDLE_OUTPUT
      $in_filter,                       # FILTER_INPUT
      $out_filter,                      # FILTER_OUTPUT
      delete $params{Driver},           # DRIVER_BOTH
      delete $params{InputState},       # EVENT_INPUT
      delete $params{ErrorState},       # EVENT_ERROR
      delete $params{FlushedState},     # EVENT_FLUSHED
      # Water marks.
      delete $params{HighMark},         # WATERMARK_MARK_HIGH
      delete $params{LowMark},          # WATERMARK_MARK_LOW
      delete $params{HighState},        # WATERMARK_EVENT_HIGH
      delete $params{LowState},         # WATERMARK_EVENT_LOW
      0,                                # WATERMARK_STATE
      # Driver statistics.
      0,                                # DRIVER_BUFFERED_OUT_OCTETS
      # Dynamic state names.
      undef,                            # STATE_WRITE
      undef,                            # STATE_READ
      # Unique ID.
      &POE::Wheel::allocate_wheel_id(), # UNIQUE_ID
    ];

  if (scalar keys %params) {
    carp( "unknown parameters in $type constructor call: ",
          join(', ', keys %params)
        );
  }

  $self->_define_read_state();
  $self->_define_write_state();

  return $self;
}

#------------------------------------------------------------------------------
# Redefine the select-write handler.  This uses stupid closure tricks
# to prevent keeping extra references to $self around.

sub _define_write_state {
  my $self = shift;

  # Read-only members.  If any of these change, then the write state
  # is invalidated and needs to be redefined.
  my $driver        = $self->[DRIVER_BOTH];
  my $event_error   = \$self->[EVENT_ERROR];
  my $event_flushed = \$self->[EVENT_FLUSHED];
  my $high_mark     = $self->[WATERMARK_MARK_HIGH];
  my $low_mark      = $self->[WATERMARK_MARK_LOW];
  my $event_high    = \$self->[WATERMARK_EVENT_HIGH];
  my $event_low     = \$self->[WATERMARK_EVENT_LOW];
  my $unique_id     = $self->[UNIQUE_ID];

  # Read/write members.  These are done by reference, to avoid pushing
  # $self into the anonymous sub.  Extra copies of $self are bad and
  # can prevent wheels from destructing properly.
  my $is_in_high_water_state     = \$self->[WATERMARK_STATE];
  my $driver_buffered_out_octets = \$self->[DRIVER_BUFFERED_OUT_OCTETS];

  # Register the select-write handler.

  $poe_kernel->state
    ( $self->[STATE_WRITE] = $self . ' select write',
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        $$driver_buffered_out_octets = $driver->flush($handle);

        # When you can't write, nothing else matters.
        if ($!) {
          $$event_error && $k->call( $me, $$event_error,
                                     'write', ($!+0), $!, $unique_id
                                   );
          $k->select_write($handle);
        }

        # Could write, or perhaps couldn't but only because the
        # filehandle's buffer is choked.
        else {

          # In high water state?  Check for low water.  High water
          # state will never be set if $event_low is undef, so don't
          # bother checking its definedness here.
          if ($$is_in_high_water_state) {
            if ( $$driver_buffered_out_octets <= $low_mark ) {
              $$is_in_high_water_state = 0;
              $k->call( $me, $$event_low, $unique_id ) if defined $$event_low;
            }
          }

          # Not in high water state.  Check for high water.  Needs to
          # also check definedness of $$river_buffered_out_octets.
          # Although we know this ahead of time and could probably
          # optimize it away with a second state definition, it would
          # be best to wait until ReadWrite stabilizes.  That way
          # there will be only half as much code to maintain.
          elsif ( $high_mark and
                  ( $$driver_buffered_out_octets >= $high_mark )
                ) {
            $$is_in_high_water_state = 1;
            $k->call( $me, $$event_high, $unique_id ) if defined $$event_high;
          }
        }

        # All chunks written; fire off a "flushed" event.  This
        # occurs independently, so it's possible to get a low-water
        # call and a flushed call at the same time (if the low mark
        # is 1).
        unless ($$driver_buffered_out_octets) {
          $k->select_pause_write($handle);
          $$event_flushed && $k->call($me, $$event_flushed, $unique_id);
        }
      }
   );

  $poe_kernel->select_write($self->[HANDLE_OUTPUT], $self->[STATE_WRITE]);

  # Pause the write select immediately, unless output is pending.
  $poe_kernel->select_pause_write($self->[HANDLE_OUTPUT])
    unless ($self->[DRIVER_BUFFERED_OUT_OCTETS]);
}

#------------------------------------------------------------------------------
# Redefine the select-read handler.  This uses stupid closure tricks
# to prevent keeping extra references to $self around.

sub _define_read_state {
  my $self = shift;

  # Register the select-read handler.

  if (defined $self->[EVENT_INPUT]) {

    # If any of these change, then the read state is invalidated and
    # needs to be redefined.
    my $driver       = $self->[DRIVER_BOTH];
    my $input_filter = $self->[FILTER_INPUT];
    my $event_input  = \$self->[EVENT_INPUT];
    my $event_error  = \$self->[EVENT_ERROR];
    my $unique_id    = $self->[UNIQUE_ID];

    $poe_kernel->state
      ( $self->[STATE_READ] = $self . ' select read',
        sub {
                                        # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$input_filter->get($raw_input)}) {
              $k->call($me, $$event_input, $cooked_input, $unique_id);
            }
          }
          else {
            $$event_error and
              $k->call( $me, $$event_error, 'read', ($!+0), $!, $unique_id );
            $k->select_read($handle);
          }
        }
      );
                                        # register the state's select
    $poe_kernel->select_read($self->[HANDLE_INPUT], $self->[STATE_READ]);
  }
                                        # undefine the select, just in case
  else {
    $poe_kernel->select_read($self->[HANDLE_INPUT])
  }
}

#------------------------------------------------------------------------------
# Redefine events.

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  my ($redefine_read, $redefine_write) = (0, 0);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'InputState') {
      $self->[EVENT_INPUT] = $event;
      $redefine_read = 1;
    }
    elsif ($name eq 'ErrorState') {
      $self->[EVENT_ERROR] = $event;
      $redefine_read = $redefine_write = 1;
    }
    elsif ($name eq 'FlushedState') {
      $self->[EVENT_FLUSHED] = $event;
      $redefine_write = 1;
    }
    elsif ($name eq 'HighState') {
      if (defined $self->[WATERMARK_MARK_HIGH]) {
        $self->[WATERMARK_EVENT_HIGH] = $event;
        $redefine_write = 1;
      }
      else {
        carp "Ignoring HighState event (there is no high watermark set)";
      }
    }
    elsif ($name eq 'LowState') {
      if (defined $self->[WATERMARK_MARK_LOW]) {
        $self->[WATERMARK_EVENT_LOW] = $event;
        $redefine_write = 1;
      }
      else {
        carp "Ignoring LowState event (there is no high watermark set)";
      }
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
    }
  }

  $self->_define_read_state()  if $redefine_read;
  $self->_define_write_state() if $redefine_write;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  # Turn off the select.  This is a problem if a wheel is being
  # swapped, since it will turn off selects for the other wheel.
  $poe_kernel->select($self->[HANDLE_INPUT]);

  if ($self->[STATE_READ]) {
    $poe_kernel->state($self->[STATE_READ]);
    $self->[STATE_READ] = undef;
  }

  $poe_kernel->select($self->[HANDLE_OUTPUT]);

  if ($self->[STATE_WRITE]) {
    $poe_kernel->state($self->[STATE_WRITE]);
    $self->[STATE_WRITE] = undef;
  }

  &POE::Wheel::free_wheel_id($self->[UNIQUE_ID]);
}

#------------------------------------------------------------------------------

sub put {
  my ($self, @chunks) = @_;
  if ( $self->[DRIVER_BUFFERED_OUT_OCTETS] =
       $self->[DRIVER_BOTH]->put($self->[FILTER_OUTPUT]->put(\@chunks))
  ) {
    $poe_kernel->select_resume_write($self->[HANDLE_OUTPUT]);
  }

  # Return true if the high watermark has been reached.
  ( $self->[WATERMARK_MARK_HIGH] &&
    $self->[DRIVER_BUFFERED_OUT_OCTETS] >= $self->[WATERMARK_MARK_HIGH]
  );
}

#------------------------------------------------------------------------------
# Redefine filter. -PG / Now that there are two filters internally,
# one input and one output, make this set both of them at the same
# time. -RC

sub set_filter {
  my ($self, $new_filter) = @_;
  my $buf = $self->[FILTER_INPUT]->get_pending();
  $self->[FILTER_INPUT] = $self->[FILTER_OUTPUT] = $new_filter;

  # Updates a closure dealing with the input filter.
  $self->_define_read_state();

  # Push pending data from the old filter into the new one.
  if (defined $buf) {
    foreach my $cooked_input (@{$new_filter->get($buf)}) {
      $poe_kernel->yield( $self->[EVENT_INPUT],
                          $cooked_input, $self->[UNIQUE_ID]
                        );
    }
  }
}

# Redefine input and/or output filters separately.
sub set_input_filter {
  my ($self, $new_filter) = @_;
  my $buf = $self->[FILTER_INPUT]->get_pending();
  $self->[FILTER_INPUT] = $new_filter;

  # Updates a closure dealing with the input filter.
  $self->_define_read_state();

  if (defined $buf) {
    foreach my $cooked_input (@{$new_filter->get($buf)}) {
      $poe_kernel->yield( $self->[EVENT_INPUT],
                          $cooked_input, $self->[UNIQUE_ID]
                        );
    }
  }
}

# No closures need to be redefined or anything.  All the previously
# put stuff has been serialized already.
sub set_output_filter {
  my ($self, $new_filter) = @_;
  $self->[FILTER_OUTPUT] = $new_filter;
}

# Set the high water mark.

sub set_high_mark {
  my ($self, $new_high_mark) = @_;
  if (defined $self->[WATERMARK_MARK_HIGH]) {
    if (defined $new_high_mark) {
      if ($new_high_mark > $self->[WATERMARK_MARK_LOW]) {
        $self->[WATERMARK_MARK_HIGH] = $new_high_mark;
        $self->_define_write_state();
      }
      else {
        carp "New high mark would not be greater than low mark.  Ignored";
      }
    }
    else {
      carp "New high mark is undefined.  Ignored";
    }
  }
  else {
    carp "Ignoring high mark (must be initialized in constructor first)";
  }
}

sub set_low_mark {
  my ($self, $new_low_mark) = @_;
  if (defined $self->[WATERMARK_MARK_LOW]) {
    if (defined $new_low_mark) {
      if ($new_low_mark > 0) {
        if ($new_low_mark < $self->[WATERMARK_MARK_HIGH]) {
          $self->[WATERMARK_MARK_LOW] = $new_low_mark;
          $self->_define_write_state();
        }
        else {
          carp "New low mark would not be less than high high mark.  Ignored";
        }
      }
      else {
        carp "New low mark would be less than one.  Ignored";
      }
    }
    else {
      carp "New low mark is undefined.  Ignored";
    }
  }
  else {
    carp "Ignoring low mark (must be initialized in constructor first)";
  }
}

# Return driver statistics.
sub get_driver_out_octets {
  $_[0]->[DRIVER_BUFFERED_OUT_OCTETS];
}

sub get_driver_out_messages {
  $_[0]->[DRIVER_BOTH]->get_out_messages_buffered();
}

# Get the wheel's ID.
sub ID {
  return $_[0]->[UNIQUE_ID];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ReadWrite - buffered non-blocking I/O

=head1 SYNOPSIS

  $wheel = new POE::Wheel::ReadWrite(

    # To read and write from the same handle, such as a socket, use
    # the Handle parameter:
    Handle       => $file_or_socket_handle,       # Handle to read/write

    # To read and write from different handles, such as a dual pipe to
    # a child process, or a console, use InputHandle and OutputHandle:
    InputHandle  => $readable_filehandle,         # Handle to read
    OutputHandle => $writable_filehandle,         # Handle to write

    Driver       => new POE::Driver::Something(), # How to read/write it

    # To read and write using the same line discipline, such as
    # Filter::Line, use the Filter parameter:
    Filter       => new POE::Filter::Something(), # How to parse in and out

    # To read and write using different line disciplines, such as
    # stream out and line in:
    InputFilter  => new POE::Filter::Something(),     # Read data one way
    OUtputFilter => new POE::Filter::SomethingElse(), # Write data another

    InputState   => $input_state_name,  # Input received state
    FlushedState => $flush_state_name,  # Output flushed state
    ErrorState   => $error_state_name,  # Error occurred state

    # To enable callbacks for high and low water events (using any one
    # of these options requires the rest):
    HighMark  => $high_mark_octets, # Outgoing high-water mark
    HighState => $high_mark_state,  # State to call when high-water reached
    LowMark   => $low_mark_octets,  # Outgoing low-water mark
    LowState  => $low_mark_state,   # State to call when low-water reached
  );

  $wheel->put( $something );
  $wheel->event( ... );

  # To set both the input and output filters at once:
  $wheel->set_filter( new POE::Filter::Something );

  # To set an input filter or an output filter:
  $wheel->set_input_filter( new POE::Filter::Something );
  $wheel->set_output_filter( new POE::Filter::Something );

  # To alter the high or low water marks:
  $wheel->set_high_mark( $new_high_mark_octets );
  $wheel->set_low_mark( $new_low_mark_octets );

  # To fetch driver statistics:
  $pending_octets   = $wheel->get_driver_out_octets();
  $pending_messages = $wheel->get_driver_out_messages();

  # To retrieve the wheel's ID:
  print $wheel->ID;

=head1 DESCRIPTION

ReadWrite performs buffered, select-based I/O on filehandles.  It
generates events for common file conditions, such as when data has
been read or flushed.

=head1 PUBLIC METHODS

=over 4

=item put LISTREF_OF_RECORDS

put() queues records for transmission.  They may not be transmitted
immediately.  ReadWrite uses its Filter to translate the records into
a form suitable for writing.  It uses its Driver to queue and send
them.

put() accepts a reference to a list of records.  It returns a boolean
value indicating whether the wheel's high-water mark has been reached.
It always returns false if a wheel doesn't have a high-water mark set.

This will quickly fill a wheel's output queue if it has a high-water
mark set.  Otherwise it will loop infinitely, eventually exhausting
memory.

  1 while $wheel->put( &get_next_thing_to_send );

=item event EVENT_TYPE => EVENT_NAME, ...

event() is covered in the POE::Wheel manpage.

=item set_filter POE_FILTER
=item set_input_filter POE_FILTER
=item set_output_filter POE_FILTER

set_input_filter() changes the filter a wheel uses for reading.
set_output_filter() changes a wheel's output filter.  set_filter()
changes them both at once.

These methods let programs change a wheel's underlying protocol while
it runs.  It retrieves the existing filter's unprocessed input using
its get_pending() method and passes that to the new filter.

Switching filters can be tricky.  Please see the discussion of
get_pending() in L<POE::Filter>.

The HTTPD filter does not support get_pending(), and it will complain
if a program tries to switch away from one.

=item set_high_mark HIGH_MARK_OCTETS
=item set_low_mark LOW_MARK_OCTETS

These methods set a wheel's high- and low-water marks.  New values
will not take effect until the next put() call or internal buffer
flush.  The event() method can change the events emitted by high- and
low-water marks.

=item ID

The ID method returns a FollowTail wheel's unique ID.  This ID will be
included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item InputState

InputState contains the event that the wheel emits for every complete
record read.  Every InputState event is accompanied by two parameters.
C<ARG0> contains the record which was read.  C<ARG1> contains the
wheel's unique ID.

A sample InputState event handler:

  sub input_state {
    my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
    print "Echoing input from wheel $wheel_id: $input\n";
    $heap->{wheel}->put($input);     # Echo it back.
  }

=item FlushedState

FlushedState contains the event that ReadWrite emits whenever its
output queue becomes empty.  This signals that all pending data has
been written, and it's often used to wait for "goodbye" messages to be
sent before a session shuts down.

FlushedState comes with a single parameter, C<ARG0>, that indicates
which wheel flushed its buffer.

A sample FlushedState event handler:

  sub flushed_state {
    # Stop a wheel after all outgoing data is flushed.
    # This frees the wheel's resources, including the
    # filehandle, and closes the connection.
    delete $_[HEAP]->{wheel}->{$_[ARG0]};
  }

=item ErrorState

ErrorState contains the event that ReadWrite emits whenever an error
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
    delete $heap->{wheels}->{$wheel_id}; # shut down that wheel
  }

=item HighState
=item LowState

ReadWrite emits a HighState event when a wheel's pending output queue
has grown to be at least HighMark octets.  A LowState event is emitted
when a wheel's pending octet count drops below the value of LowMark.

HighState and LowState flip-flop.  Once a HighState event has been
fired, it won't be fired again until LowState's event is.  Likewise,
LowState will not be fired again until HighState is.  ReadWrite always
starts in a low-water state.

Streaming sessions are encouraged to used these states for flow
control.  Sessions can reduce their transmission rates or stop
transmitting altogether upon receipt of a HighState event.  They can
resume full-speed transmission once LowState arrives.

=back

=head1 SEE ALSO

POE::Wheel.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
