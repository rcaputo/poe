# $Id$

package POE::Wheel::ReadWrite;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use Carp qw( croak carp );
use POE qw(Wheel Driver::SysRW Filter::Line);

# Offsets into $self.
sub HANDLE_INPUT               () {  0 }
sub HANDLE_OUTPUT              () {  1 }
sub FILTER_INPUT               () {  2 }
sub FILTER_OUTPUT              () {  3 }
sub DRIVER_BOTH                () {  4 }
sub EVENT_INPUT                () {  5 }
sub EVENT_ERROR                () {  6 }
sub EVENT_FLUSHED              () {  7 }
sub WATERMARK_WRITE_MARK_HIGH  () {  8 }
sub WATERMARK_WRITE_MARK_LOW   () {  9 }
sub WATERMARK_WRITE_EVENT_HIGH () { 10 }
sub WATERMARK_WRITE_EVENT_LOW  () { 11 }
sub WATERMARK_WRITE_STATE      () { 12 }
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
    carp "Ignoring OutputFilter parameter (Filter parameter takes precedence)"
      if (defined $params{OutputFilter});
    $in_filter = $out_filter = delete $params{Filter};
  }
  else {
    $in_filter = delete $params{InputFilter};
    $out_filter = delete $params{OutputFilter};

    # If neither Filter, InputFilter or OutputFilter is defined, then
    # they default to POE::Filter::Line.
    unless (defined $in_filter and defined $out_filter) {
      my $new_filter = POE::Filter::Line->new();
      $in_filter = $new_filter unless defined $in_filter;
      $out_filter = $new_filter unless defined $out_filter;
    }
  }

  my $driver = delete $params{Driver};
  $driver = POE::Driver::SysRW->new() unless defined $driver;

  { my $mark_errors = 0;
    if (defined($params{HighMark}) xor defined($params{LowMark})) {
      carp "HighMark and LowMark parameters require each-other";
      $mark_errors++;
    }
    # Then they both exist, and they must be checked.
    elsif (defined $params{HighMark}) {
      unless (defined($params{HighMark}) and defined($params{LowMark})) {
        carp "HighMark and LowMark parameters must both be defined";
        $mark_errors++;
      }
      unless (($params{HighMark} > 0) and ($params{LowMark} > 0)) {
        carp "HighMark and LowMark parameters must be above 0";
        $mark_errors++;
      }
    }
    if (defined($params{HighMark}) xor defined($params{HighEvent})) {
      carp "HighMark and HighEvent parameters require each-other";
      $mark_errors++;
    }
    if (defined($params{LowMark}) xor defined($params{LowEvent})) {
      carp "LowMark and LowEvent parameters require each-other";
      $mark_errors++;
    }
    croak "Water mark errors" if $mark_errors;
  }

  my $self = bless [
    $in_handle,                       # HANDLE_INPUT
    $out_handle,                      # HANDLE_OUTPUT
    $in_filter,                       # FILTER_INPUT
    $out_filter,                      # FILTER_OUTPUT
    $driver,                          # DRIVER_BOTH
    delete $params{InputEvent},       # EVENT_INPUT
    delete $params{ErrorEvent},       # EVENT_ERROR
    delete $params{FlushedEvent},     # EVENT_FLUSHED
    # Water marks.
    delete $params{HighMark},         # WATERMARK_WRITE_MARK_HIGH
    delete $params{LowMark},          # WATERMARK_WRITE_MARK_LOW
    delete $params{HighEvent},        # WATERMARK_WRITE_EVENT_HIGH
    delete $params{LowEvent},         # WATERMARK_WRITE_EVENT_LOW
    0,                                # WATERMARK_WRITE_STATE
    # Driver statistics.
    0,                                # DRIVER_BUFFERED_OUT_OCTETS
    # Dynamic state names.
    undef,                            # STATE_WRITE
    undef,                            # STATE_READ
    # Unique ID.
    &POE::Wheel::allocate_wheel_id(), # UNIQUE_ID
  ], $type;

  if (scalar keys %params) {
    carp(
      "unknown parameters in $type constructor call: ",
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
  my $high_mark     = $self->[WATERMARK_WRITE_MARK_HIGH];
  my $low_mark      = $self->[WATERMARK_WRITE_MARK_LOW];
  my $event_error   = \$self->[EVENT_ERROR];
  my $event_flushed = \$self->[EVENT_FLUSHED];
  my $event_high    = \$self->[WATERMARK_WRITE_EVENT_HIGH];
  my $event_low     = \$self->[WATERMARK_WRITE_EVENT_LOW];
  my $unique_id     = $self->[UNIQUE_ID];

  # Read/write members.  These are done by reference, to avoid pushing
  # $self into the anonymous sub.  Extra copies of $self are bad and
  # can prevent wheels from destructing properly.
  my $is_in_high_water_state     = \$self->[WATERMARK_WRITE_STATE];
  my $driver_buffered_out_octets = \$self->[DRIVER_BUFFERED_OUT_OCTETS];

  # Register the select-write handler.

  $poe_kernel->state(
    $self->[STATE_WRITE] = ref($self) . "($unique_id) -> select write",
    sub {                             # prevents SEGV
      0 && CRIMSON_SCOPE_HACK('<');
                                      # subroutine starts here
      my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

      $$driver_buffered_out_octets = $driver->flush($handle);

      # When you can't write, nothing else matters.
      if ($!) {
        $$event_error && $k->call(
          $me, $$event_error, 'write', ($!+0), $!, $unique_id
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
        # also check definedness of $$driver_buffered_out_octets.
        # Although we know this ahead of time and could probably
        # optimize it away with a second state definition, it would
        # be best to wait until ReadWrite stabilizes.  That way
        # there will be only half as much code to maintain.
        elsif (
          $high_mark and
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
    my $input_filter = \$self->[FILTER_INPUT];
    my $event_input  = \$self->[EVENT_INPUT];
    my $event_error  = \$self->[EVENT_ERROR];
    my $unique_id    = $self->[UNIQUE_ID];

    # If the filter can get_one, then define the input state in terms
    # of get_one_start() and get_one().

    if (
      $$input_filter->can('get_one') and
      $$input_filter->can('get_one_start')
    ) {
      $poe_kernel->state(
        $self->[STATE_READ] = ref($self) . "($unique_id) -> select read",
        sub {

          # Protects against coredump on older perls.
          0 && CRIMSON_SCOPE_HACK('<');

          # The actual code starts here.
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            $$input_filter->get_one_start($raw_input);
            while (1) {
              my $next_rec = $$input_filter->get_one();
              last unless @$next_rec;
              foreach my $cooked_input (@$next_rec) {
                $k->call($me, $$event_input, $cooked_input, $unique_id);
              }
            }
          }
          else {
            $$event_error and $k->call(
              $me, $$event_error, 'read', ($!+0), $!, $unique_id
            );
            $k->select_read($handle);
          }
        }
      );
    }

    # Otherwise define the input state in terms of the older, less
    # robust, yet faster get().

    else {
      $poe_kernel->state(
        $self->[STATE_READ] = ref($self) . "($unique_id) -> select read",
        sub {

          # Protects against coredump on older perls.
          0 && CRIMSON_SCOPE_HACK('<');

          # The actual code starts here.
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$$input_filter->get($raw_input)}) {
              $k->call($me, $$event_input, $cooked_input, $unique_id);
            }
          }
          else {
            $$event_error and $k->call(
              $me, $$event_error, 'read', ($!+0), $!, $unique_id
            );
            $k->select_read($handle);
          }
        }
      );
    }
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

    if ($name eq 'InputEvent') {
      $self->[EVENT_INPUT] = $event;
      $redefine_read = 1;
    }
    elsif ($name eq 'ErrorEvent') {
      $self->[EVENT_ERROR] = $event;
      $redefine_read = $redefine_write = 1;
    }
    elsif ($name eq 'FlushedEvent') {
      $self->[EVENT_FLUSHED] = $event;
      $redefine_write = 1;
    }
    elsif ($name eq 'HighEvent') {
      if (defined $self->[WATERMARK_WRITE_MARK_HIGH]) {
        $self->[WATERMARK_WRITE_EVENT_HIGH] = $event;
        $redefine_write = 1;
      }
      else {
        carp "Ignoring HighEvent (there is no high watermark set)";
      }
    }
    elsif ($name eq 'LowEvent') {
      if (defined $self->[WATERMARK_WRITE_MARK_LOW]) {
        $self->[WATERMARK_WRITE_EVENT_LOW] = $event;
        $redefine_write = 1;
      }
      else {
        carp "Ignoring LowEvent (there is no high watermark set)";
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
  if ($self->[HANDLE_INPUT]) {
    $poe_kernel->select($self->[HANDLE_INPUT]);
    $self->[HANDLE_INPUT] = undef;
  }

  if ($self->[HANDLE_OUTPUT]) {
    $poe_kernel->select($self->[HANDLE_OUTPUT]);
    $self->[HANDLE_OUTPUT] = undef;
  }

  if ($self->[STATE_READ]) {
    $poe_kernel->state($self->[STATE_READ]);
    $self->[STATE_READ] = undef;
  }

  if ($self->[STATE_WRITE]) {
    $poe_kernel->state($self->[STATE_WRITE]);
    $self->[STATE_WRITE] = undef;
  }

  &POE::Wheel::free_wheel_id($self->[UNIQUE_ID]);
}

#------------------------------------------------------------------------------
# TODO - We set the high/low watermark state here, but we don't fire
# events for it.  My assumption is that the return value tells us
# all we want to know.

sub put {
  my ($self, @chunks) = @_;

  my $old_buffered_out_octets = $self->[DRIVER_BUFFERED_OUT_OCTETS];
  my $new_buffered_out_octets =
    $self->[DRIVER_BUFFERED_OUT_OCTETS] =
    $self->[DRIVER_BOTH]->put($self->[FILTER_OUTPUT]->put(\@chunks));

  # Resume write-ok if the output buffer gets data.  This avoids
  # redundant calls to select_resume_write(), which is probably a good
  # thing.
  if ($new_buffered_out_octets and !$old_buffered_out_octets) {
    $poe_kernel->select_resume_write($self->[HANDLE_OUTPUT]);
  }

  # If the high watermark has been reached, return true.
  if (
    $self->[WATERMARK_WRITE_MARK_HIGH] and
    $new_buffered_out_octets >= $self->[WATERMARK_WRITE_MARK_HIGH]
  ) {
    return $self->[WATERMARK_WRITE_STATE] = 1;
  }

  return $self->[WATERMARK_WRITE_STATE] = 0;
}

#------------------------------------------------------------------------------
# Redefine filter. -PG / Now that there are two filters internally,
# one input and one output, make this set both of them at the same
# time. -RCC

sub _transfer_input_buffer {
  my ($self, $buf) = @_;

  my $old_input_filter = $self->[FILTER_INPUT];

  # If the new filter implements "get_one", use that.
  if (
    $old_input_filter->can('get_one') and
    $old_input_filter->can('get_one_start')
  ) {
    if (defined $buf) {
      $self->[FILTER_INPUT]->get_one_start($buf);
      while ($self->[FILTER_INPUT] == $old_input_filter) {
        my $next_rec = $self->[FILTER_INPUT]->get_one();
        last unless @$next_rec;
        foreach my $cooked_input (@$next_rec) {
          $poe_kernel->call(
            $poe_kernel->get_active_session(),
            $self->[EVENT_INPUT],
            $cooked_input, $self->[UNIQUE_ID]
          );
        }
      }
    }
  }

  # Otherwise use the old behavior.
  else {
    if (defined $buf) {
      foreach my $cooked_input (@{$self->[FILTER_INPUT]->get($buf)}) {
        $poe_kernel->call(
          $poe_kernel->get_active_session(),
          $self->[EVENT_INPUT],
          $cooked_input, $self->[UNIQUE_ID]
        );
      }
    }
  }
}

# Set input and output filters.

sub set_filter {
  my ($self, $new_filter) = @_;
  my $buf = $self->[FILTER_INPUT]->get_pending();
  $self->[FILTER_INPUT] = $self->[FILTER_OUTPUT] = $new_filter;

  $self->_transfer_input_buffer($buf);
}

# Redefine input and/or output filters separately.
sub set_input_filter {
  my ($self, $new_filter) = @_;
  my $buf = $self->[FILTER_INPUT]->get_pending();
  $self->[FILTER_INPUT] = $new_filter;

  $self->_transfer_input_buffer($buf);
}

# No closures need to be redefined or anything.  All the previously
# put stuff has been serialized already.
sub set_output_filter {
  my ($self, $new_filter) = @_;
  $self->[FILTER_OUTPUT] = $new_filter;
}

# Get the current input filter; used for accessing the filter's custom
# methods, as in: $wheel->get_input_filter()->filter_method();
sub get_input_filter {
  my $self = shift;
  return $self->[FILTER_INPUT];
}

# Get the current input filter; used for accessing the filter's custom
# methods, as in: $wheel->get_input_filter()->filter_method();
sub get_output_filter {
  my $self = shift;
  return $self->[FILTER_OUTPUT];
}

# Set the high water mark.

sub set_high_mark {
  my ($self, $new_high_mark) = @_;

  unless (defined $self->[WATERMARK_WRITE_MARK_HIGH]) {
    carp "Ignoring high mark (must be initialized in constructor first)";
    return;
  }

  unless (defined $new_high_mark) {
    carp "New high mark is undefined.  Ignored";
    return;
  }

  unless ($new_high_mark > $self->[WATERMARK_WRITE_MARK_LOW]) {
    carp "New high mark would not be greater than low mark.  Ignored";
    return;
  }

  $self->[WATERMARK_WRITE_MARK_HIGH] = $new_high_mark;
  $self->_define_write_state();
}

sub set_low_mark {
  my ($self, $new_low_mark) = @_;

  unless (defined $self->[WATERMARK_WRITE_MARK_LOW]) {
    carp "Ignoring low mark (must be initialized in constructor first)";
    return;
  }

  unless (defined $new_low_mark) {
    carp "New low mark is undefined.  Ignored";
    return;
  }

  unless ($new_low_mark > 0) {
    carp "New low mark would be less than one.  Ignored";
    return;
  }

  unless ($new_low_mark < $self->[WATERMARK_WRITE_MARK_HIGH]) {
    carp "New low mark would not be less than high high mark.  Ignored";
    return;
  }

  $self->[WATERMARK_WRITE_MARK_LOW] = $new_low_mark;
  $self->_define_write_state();
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

# Pause the wheel's input watcher.
sub pause_input {
  my $self = shift;
  return unless defined $self->[HANDLE_INPUT];
  $poe_kernel->select_pause_read( $self->[HANDLE_INPUT] );
}

# Resume the wheel's input watcher.
sub resume_input {
  my $self = shift;
  return unless  defined $self->[HANDLE_INPUT];
  $poe_kernel->select_resume_read( $self->[HANDLE_INPUT] );
}

# Return the wheel's input handle
sub get_input_handle {
  my $self = shift;
  return $self->[HANDLE_INPUT];
}

# Return the wheel's output handle
sub get_output_handle {
  my $self = shift;
  return $self->[HANDLE_OUTPUT];
}

# Shutdown the socket for reading.
sub shutdown_input {
  my $self = shift;
  return unless defined $self->[HANDLE_INPUT];
  eval { local $^W = 0; shutdown($self->[HANDLE_INPUT], 0) };
  $poe_kernel->select_read($self->[HANDLE_INPUT], undef);
}

# Shutdown the socket for writing.
sub shutdown_output {
  my $self = shift;
  return unless defined $self->[HANDLE_OUTPUT];
  eval { local $^W=0; shutdown($self->[HANDLE_OUTPUT], 1) };
  $poe_kernel->select_write($self->[HANDLE_OUTPUT], undef);
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ReadWrite - buffered non-blocking I/O

=head1 SYNOPSIS

  $wheel = POE::Wheel::ReadWrite->new(

    # To read and write from the same handle, such as a socket, use
    # the Handle parameter:
    Handle       => $file_or_socket_handle,  # Handle to read/write

    # To read and write from different handles, such as a dual pipe to
    # a child process, or a console, use InputHandle and OutputHandle:
    InputHandle  => $readable_filehandle,    # Handle to read
    OutputHandle => $writable_filehandle,    # Handle to write

    Driver       => POE::Driver::Something->new(), # How to read/write it

    # To read and write using the same line discipline, such as
    # Filter::Line, use the Filter parameter:
    Filter       => POE::Filter::Something->new(), # How to parse in and out

    # To read and write using different line disciplines, such as
    # stream out and line in:
    InputFilter  => POE::Filter::Something->new(),     # Read data one way
    OutputFilter => POE::Filter::SomethingElse->new(), # Write data another

    InputEvent   => $input_event_name,  # Input received event
    FlushedEvent => $flush_event_name,  # Output flushed event
    ErrorEvent   => $error_event_name,  # Error occurred event

    # To enable callbacks for high and low water events (using any one
    # of these options requires the rest):
    HighMark  => $high_mark_octets, # Outgoing high-water mark
    HighEvent => $high_mark_event,  # Event to emit when high-water reached
    LowMark   => $low_mark_octets,  # Outgoing low-water mark
    LowEvent  => $low_mark_event,   # Event to emit when low-water reached
  );

  $wheel->put( $something );
  $wheel->event( ... );

  # To set both the input and output filters at once:
  $wheel->set_filter( POE::Filter::Something->new() );

  # To set an input filter or an output filter:
  $wheel->set_input_filter( POE::Filter::Something->new() );
  $wheel->set_output_filter( POE::Filter::Something->new() );

  # To alter the high or low water marks:
  $wheel->set_high_mark( $new_high_mark_octets );
  $wheel->set_low_mark( $new_low_mark_octets );

  # To fetch driver statistics:
  $pending_octets   = $wheel->get_driver_out_octets();
  $pending_messages = $wheel->get_driver_out_messages();

  # To retrieve the wheel's ID:
  print $wheel->ID;

  # To pause and resume a wheel's input events.
  $wheel->pause_input();
  $wheel->resume_input();

  # To shutdown a wheel's socket(s).
  $wheel->shutdown_input();
  $wheel->shutdown_output();

=head1 DESCRIPTION

ReadWrite performs buffered, select-based I/O on filehandles.  It
generates events for common file conditions, such as when data has
been read or flushed.

=head1 CONSTRUCTOR

=over

=item new

new() creates a new wheel, returning the wheels reference.

=back

=head1 PUBLIC METHODS

=over 2

=item put RECORDS

put() queues one or more RECORDS for transmission.  Each record is of
a form dictated by POE::Wheel::ReadWrite's current output filter.
ReadWrite uses its output filter to translate the records into a form
suitable for writing to a stream.  It uses the currently configured
driver to buffer and send them.

put() accepts a list of records.  If a high water mark has been set,
it returns a Boolean value indicating whether the driver's output
buffer has reached that level.  It always returns false if a high
water mark has not been set.

This example will quickly fill a wheel's output queue if it has a
high water mark set.  Otherwise it will loop infinitely, eventually
exhausting memory and crashing.

  1 while $wheel->put( get_next_thing_to_send() );

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

=item get_input_filter

=item get_output_filter

Return the wheel's input or output filter.  In many cases, they both
may be the same.  This is used to access custom methods on the filter
itself; for example, Filter::Stackable has methods to push and pop
filters on its stack.

  $wheel->get_input_filter()->pop();

=item set_high_mark HIGH_MARK_OCTETS

=item set_low_mark LOW_MARK_OCTETS

These methods set a wheel's high- and low-water marks.  New values
will not take effect until the next put() call or internal buffer
flush.  The event() method can change the events emitted by high- and
low-water marks.

=item ID

The ID method returns a ReadWrite wheel's unique ID.  This ID will be
included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=item pause_input

=item resume_input

ReadWrite wheels will continually generate input events for as long as
they have data to read.  Sometimes it's necessary to control the flow
of data coming from a wheel or the input filehandle it manages.

pause_input() instructs the wheel to temporarily stop checking its
input filehandle for data.  This can keep a session (or a
corresponding output buffer) from being overwhelmed.

resume_input() instructs the wheel to resume checking its input
filehandle for data.

=item get_input_handle

=item get_output_handle

These methods return the input and output handles (usually the same
thing, but sometimes not).  Please use sparingly.  Remember odd 
references will screw with POE's internals.

=item shutdown_input

=item shutdown_output

Some applications require the remote end to shut down a socket before
they will continue.  These methods map directly to shutdown() for the
wheel's input and output sockets.

=item get_driver_out_octets

=item get_driver_out_messages

Return driver statistics.

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item Driver

Driver is a POE::Driver subclass that is used to read from and write
to ReadWrite's filehandle(s).  It encapsulates the low-level I/O
operations so in theory ReadWrite never needs to know about them.

Driver defaults to C<<POE::Driver::SysRW->new()>>.

=item Filter

Filter is a POE::Filter subclass that's used to parse incoming data
and create streamable outgoing data.  It encapsulates the lowest level
of a protocol so in theory ReadWrite never needs to know about them.

Filter defaults to C<<POE::Filter::Line->new()>>.

=item InputEvent

InputEvent contains the event that the wheel emits for every complete
record read.  Every InputEvent is accompanied by two parameters.
C<ARG0> contains the record which was read.  C<ARG1> contains the
wheel's unique ID.

The wheel will not attempt to read from its Handle or InputHandle if
InputEvent is omitted.

A sample InputEvent handler:

  sub input_state {
    my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
    print "Echoing input from wheel $wheel_id: $input\n";
    $heap->{wheel}->put($input);     # Echo it back.
  }

=item FlushedEvent

FlushedEvent contains the event that ReadWrite emits whenever its
output queue becomes empty.  This signals that all pending data has
been written, and it's often used to wait for "goodbye" messages to be
sent before a session shuts down.

FlushedEvent comes with a single parameter, C<ARG0>, that indicates
which wheel flushed its buffer.

A sample FlushedEvent handler:

  sub flushed_state {
    # Stop a wheel after all outgoing data is flushed.
    # This frees the wheel's resources, including the
    # filehandle, and closes the connection.
    delete $_[HEAP]->{wheel}->{$_[ARG0]};
  }

=item ErrorEvent

ErrorEvent contains the event that ReadWrite emits whenever an error
occurs.  Every ErrorEvent comes with four parameters:

C<ARG0> contains the name of the operation that failed.  This usually
is 'read'.  Note: This is not necessarily a function name.  The wheel
doesn't know which function its Driver is using.

C<ARG1> and C<ARG2> hold numeric and string values for C<$!>,
respectively.

C<ARG3> contains the wheel's unique ID.

A sample ErrorEvent handler:

  sub error_state {
    my ($operation, $errnum, $errstr, $wheel_id) = @_[ARG0..ARG3];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
    delete $heap->{wheels}->{$wheel_id}; # shut down that wheel
  }

=item HighEvent

=item LowEvent

ReadWrite emits a HighEvent when a wheel's pending output queue has
grown to be at least HighMark octets.  A LowEvent is emitted when a
wheel's pending octet count drops below the value of LowMark.

HighEvent and LowEvent flip-flop.  Once a HighEvent has been emitted,
it won't be emitted again until a LowEvent is emitted.  Likewise,
LowEvent will not be emitted again until HighEvent is.  ReadWrite
always starts in a low-water state.

Sessions which stream output are encouraged to use these events for
flow control.  Sessions can reduce their transmission rates or stop
transmitting altogether upon receipt of a HighEvent, and they can
resume full-speed transmission once LowEvent arrives.

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
