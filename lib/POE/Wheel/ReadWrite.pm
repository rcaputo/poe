# $Id$

package POE::Wheel::ReadWrite;

use strict;
use Carp;
use POE;

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

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  my ($in_handle, $out_handle);
  if (exists $params{Handle}) {
    carp "Ignoring InputHandle parameter (Handle parameter takes precedence)"
      if (exists $params{InputHandle});
    carp "Ignoring OutputHandle parameter (Handle parameter takes precedence)"
      if (exists $params{OutputHandle});
    $in_handle = $out_handle = $params{Handle};
  }
  else {
    croak "Handle or InputHandle required"
      unless (exists $params{InputHandle});
    croak "Handle or OutputHandle required"
      unless (exists $params{OutputHandle});
    $in_handle = $params{InputHandle};
    $out_handle = $params{OutputHandle};
  }

  my ($in_filter, $out_filter);
  if (exists $params{Filter}) {
    carp "Ignoring InputFilter parameter (Filter parameter takes precedence)"
      if (exists $params{InputFilter});
    carp "Ignoring OUtputFilter parameter (Filter parameter takes precedence)"
      if (exists $params{OutputFilter});
    $in_filter = $out_filter = $params{Filter};
  }
  else {
    croak "Filter or InputFilter required"
      unless exists $params{InputFilter};
    croak "Filter or OutputFilter required"
      unless exists $params{OutputFilter};
    $in_filter = $params{InputFilter};
    $out_filter = $params{OutputFilter};
  }

  croak "Driver required" unless (exists $params{Driver});

  { my $mark_errors = 0;
    if (exists($params{HighMark}) xor exists($params{LowMark})) {
      carp "HighMark and LowMark parameters require each-other";
      $mark_errors++;
    }
    # Then they both exist, and they must be checked.
    elsif (exists $params{HighMark}) {
      unless (defined($params{HighMark}) and defined($params{LowMark})) {
        carp "HighMark and LowMark parameters must be defined";
        $mark_errors++;
      }
      unless (($params{HighMark} > 0) and ($params{LowMark} > 0)) {
        carp "HighMark and LowMark parameters must above 0";
        $mark_errors++;
      }
    }
    if (exists($params{HighMark}) xor exists($params{HighState})) {
      carp "HighMark and HighState parameters require each-other";
      $mark_errors++;
    }
    if (exists($params{LowMark}) xor exists($params{LowState})) {
      carp "LowMark and LowState parameters require each-other";
      $mark_errors++;
    }
    croak "Water mark errors" if $mark_errors;
  }

  my $self = bless
    [ $in_handle,
      $out_handle,
      $in_filter,
      $out_filter,
      $params{Driver},
      $params{InputState},
      $params{ErrorState},
      $params{FlushedState},
      # Water marks.
      $params{HighMark},
      $params{LowMark},
      $params{HighState},
      $params{LowState},
      0,
      # Driver statistics.
      0,
    ];

  $self->_define_read_state();
  $self->_define_write_state();

  $self;
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

  # Read/write members.  These are done by reference, to avoid pushing
  # $self into the anonymous sub.  Extra copies of $self are bad and
  # can prevent wheels from destructing properly.
  my $is_in_high_water_state     = \$self->[WATERMARK_STATE];
  my $driver_buffered_out_octets = \$self->[DRIVER_BUFFERED_OUT_OCTETS];

  # Register the select-write handler.

  $poe_kernel->state
    ( $self->[STATE_WRITE] = $self . ' -> select write',
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        $$driver_buffered_out_octets = $driver->flush($handle);

        # When you can't write, nothing else matters.
        if ($!) {
          $$event_error && $k->call( $me, $$event_error, 'write', ($!+0), $! );
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
              $k->call( $me, $$event_low ) if defined $$event_low;
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
            $k->call( $me, $$event_high ) if defined $$event_high;
          }
        }

        # All chunks written; fire off a "flushed" event.  This
        # occurs independently, so it's possible to get a low-water
        # call and a flushed call at the same time (if the low mark
        # is 1).
        unless ($$driver_buffered_out_octets) {
          $k->select_pause_write($handle);
          $$event_flushed && $k->call($me, $$event_flushed);
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

    $poe_kernel->state
      ( $self->[STATE_READ] = $self . ' -> select read',
        sub {
                                        # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$input_filter->get($raw_input)}) {
              $k->call($me, $$event_input, $cooked_input);
            }
          }
          else {
            $$event_error and
              $k->call( $me, $$event_error, 'read', ($!+0), $! );
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
                                        # remove tentacles from our owner
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

sub set_filter
{
    my($self, $new_filter)=@_;
    my $buf=$self->[FILTER_INPUT]->get_pending();
    $self->[FILTER_INPUT]=$self->[FILTER_OUTPUT]=$new_filter;

    # Updates a closure dealing with the input filter.
    $self->_define_read_state();

    if ( defined($buf) )
    {
        foreach my $cooked_input (@{$new_filter->get($buf)})
        {
            $poe_kernel->yield($self->[EVENT_INPUT], $cooked_input)
        }
    }
}

# Redefine input and/or output filters separately.

sub set_input_filter {
    my($self, $new_filter)=@_;
    my $buf=$self->[FILTER_INPUT]->get_pending();
    $self->[FILTER_INPUT]=$new_filter;

    # Updates a closure dealing with the input filter.
    $self->_define_read_state();

    if ( defined($buf) )
    {
        foreach my $cooked_input (@{$new_filter->get($buf)})
        {
            $poe_kernel->yield($self->[EVENT_INPUT], $cooked_input)
        }
    }
}

# No closures need to be redefined or anything.  All the previously
# put stuff has been serialized already.
sub set_output_filter {
    my($self, $new_filter)=@_;
    $self->[FILTER_OUTPUT]=$new_filter;
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

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ReadWrite - POE Read/Write Logic Abstraction

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

=head1 DESCRIPTION

The ReadWrite wheel does buffered, select-based I/O on a filehandle.
It generates events for common file conditions, such as when data has
been read or flushed.  This wheel includes a put() method.

=head1 PUBLIC METHODS

=over 4

=item *

POE::Wheel::ReadWrite::put($logical_data_chunk)

The put() method uses a POE::Filter to translate the logical data
chunk into a serialized (streamable) representation.  It then uses a
POE::Driver to enqueue or write the data to a filehandle.  It also
manages the wheel's write select so that any buffered data can be
flushed when the handle is ready.

The put() method returns a boolean value indicating whether the
wheel's high water mark has been reached.  It will always return false
if the wheel doesn't have a high water mark set.

Data isn't flushed to the underlying filehandle, so it's easy for
put() to exceed a wheel's high water mark without generating a
HighState event.

=item *

POE::Wheel::ReadWrite::event(...)

Please see POE::Wheel.

=item *

POE::Wheel::ReadWrite::set_filter( $poe_filter )

The set_filter method changes the filter that the ReadWrite wheel uses
to translate between streams and logical chunks of data.  It sets both
the read and write filters.  It uses filters' get_pending() method to
preserve any unprocessed input between the previous and new filters.

Please be aware that this method has complex and perhaps non-obvious
side effects.  The description of POE::Filter::get_pending() discusses
them further.

POE::Filter::HTTPD does not support the get_pending() method.
Switching from an HTTPD filter to another one will display a reminder
that it sn't supported.

=item *

POE::Wheel::ReadWrite::set_input_filter( $poe_filter )
POE::Wheel::ReadWrite::set_output_filter( $poe_filter )

These perform similar functions to the &set_filter method, but they
change the input or output filters separately.

=item *

POE::Wheel::ReadWrite->set_high_mark( $high_mark_octets )
POE::Wheel::ReadWrite->set_low_mark( $low_mark_octets )

Sets the high and low watermark octet counts.  They will not take
effect until the next $wheel->put() or internal buffer flush.
POE::Wheel::ReadWrite->event() can change the high and low watermark
events.

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item *

InputState

The InputState event contains the name of the state that will be
called for each chunk of logical data returned by the ReadWrite
wheel's filter.

The ARG0 parameter contains the chunk of logical data that was
received.

A sample InputState state:

  sub input_state {
    my ($heap, $input) = @_[HEAP, ARG0];
    print "Echoing input: $input\n";
    $heap->{wheel}->put($input);     # Echo it back.
  }

=item *

FlushedState

The FlushedState event contains the name of the state that will be
called whenever the wheel's driver's output queue becomes empty.  This
signals that all pending data has been written.  It does not include
parameters.

A sample FlushedState state:

  sub flushed_state {
    # Stop the wheel after all outgoing data is flushed.
    # This frees the wheel's resources, including the
    # filehandle, and closes the connection.
    delete $_[HEAP]->{wheel};
  }

=item *

ErrorState

The ErrorState event contains the name of the state that will be
called when a file error occurs.  The ReadWrite wheel knows what to do
with EAGAIN, so it's not considered a true error.

The ARG0 parameter contains the name of the function that failed.
ARG1 and ARG2 contain the numeric and string versions of $! at the
time of the error, respectively.

A sample ErrorState state:

  sub error_state {
    my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
    warn "$operation error $errnum: $errstr\n";
  }

=item *

HighState

The HighState event indicates when the wheel's driver's output buffer
has grows to reach HighMark octets of unwritten data.  This event will
fire once when the output buffer reaches HighMark, and it will not
fire again until a LowState event occurs.

HighState and LowState together are used for flow control.  The idea
is to perform some sort of throttling when HighState is called and
resume full-speed transmission when LowState is called.

HighState includes no parameters.

=item *

LowState

The LowState event indicates when a wheel's driver's output buffer
shrinks down to LowMark octets of unwritten data.  This event will
only fire when the output buffer reaches LowMark after a HighState event.

HighState and LowState together are used for flow control.  The idea
is to perform some sort of throttling when HighState is called and
resume full-speed transmission when LowState is called.

LowState includes no parameters.

=back

=head1 SEE ALSO

POE::Wheel; POE::Wheel::FollowTail; POE::Wheel::ListenAccept;
POE::Wheel::SocketFactory

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
