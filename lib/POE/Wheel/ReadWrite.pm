# $Id$

package POE::Wheel::ReadWrite;

use strict;
use Carp;
use POE;

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

  my $self = bless { input_handle  => $in_handle,
                     output_handle => $out_handle,
                     driver        => $params{Driver},
                     input_filter  => $in_filter,
                     output_filter => $out_filter,
                     event_input   => $params{InputState},
                     event_error   => $params{ErrorState},
                     event_flushed => $params{FlushedState},
                   }, $type;

  $self->_define_read_state();
  $self->_define_write_state();

  $self;
}

#------------------------------------------------------------------------------
# Redefine the select-write handler.  This uses stupid closure tricks
# to prevent keeping extra references to $self around.

sub _define_write_state {
  my $self = shift;

  # If any of these change, then the write state is invalidated and
  # needs to be redefined.

  my $driver        = $self->{driver};
  my $event_error   = $self->{event_error};
  my $event_flushed = $self->{event_flushed};

  # Register the select-write handler.

  $poe_kernel->state
    ( $self->{state_write} = $self . ' -> select write',
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $writes_pending = $driver->flush($handle);
        if ($!) {
          $event_error && $k->call( $me, $event_error, 'write', ($!+0), $! );
          $k->select_write($handle);
        }
        elsif (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
            $event_flushed && $k->call($me, $event_flushed);
          }
        }
      }
    );
}

#------------------------------------------------------------------------------
# Redefine the select-read handler.  This uses stupid closure tricks
# to prevent keeping extra references to $self around.

sub _define_read_state {
  my $self = shift;

  # If any of these change, then the read state is invalidated and
  # needs to be redefined.

  my $driver       = $self->{driver};
  my $input_filter = $self->{input_filter};
  my $event_input  = $self->{event_input};
  my $event_error  = $self->{event_error};

  # Register the select-read handler.

  if (defined $self->{event_input}) {
    $poe_kernel->state
      ( $self->{state_read} = $self . ' -> select read',
        sub {
                                        # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$input_filter->get($raw_input)}) {
              $k->call($me, $event_input, $cooked_input);
            }
          }
          else {
            $event_error && $k->call( $me, $event_error, 'read', ($!+0), $! );
            $k->select_read($handle);
          }
        }
      );
                                        # register the state's select
    $poe_kernel->select_read($self->{input_handle}, $self->{state_read});
  }
                                        # undefine the select, just in case
  else {
    $poe_kernel->select_read($self->{input_handle})
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
      $self->{event_input} = $event;
      $redefine_read = 1;
    }
    elsif ($name eq 'ErrorState') {
      $self->{event_error} = $event;
      $redefine_read = $redefine_write = 1;
    }
    elsif ($name eq 'FlushedState') {
      $self->{event_flushed} = $event;
      $redefine_write = 1;
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
  $poe_kernel->select($self->{input_handle});

  if ($self->{state_read}) {
    $poe_kernel->state($self->{state_read});
    delete $self->{state_read};
  }

  $poe_kernel->select($self->{output_handle});

  if ($self->{state_write}) {
    $poe_kernel->state($self->{state_write});
    delete $self->{state_write};
  }
}

#------------------------------------------------------------------------------

sub put {
  my ($self, @chunks) = @_;
  if ($self->{driver}->put($self->{output_filter}->put(\@chunks))) {
    $poe_kernel->select_write($self->{output_handle}, $self->{state_write});
  }
}

#------------------------------------------------------------------------------
# Redefine filter. -PG / Now that there are two filters internally,
# one input and one output, make this set both of them at the same
# time. -RC

sub set_filter
{
    my($self, $new_filter)=@_;
    my $buf=$self->{input_filter}->get_pending();
    $self->{input_filter}=$self->{output_filter}=$new_filter;

    # Updates a closure dealing with the input filter.
    $self->_define_read_state();

    if ( defined($buf) )
    {
        foreach my $cooked_input (@{$new_filter->get($buf)})
        {
            $poe_kernel->yield($self->{event_input}, $cooked_input)
        }
    }
}

# Redefine input and/or output filters separately.

sub set_input_filter {
    my($self, $new_filter)=@_;
    my $buf=$self->{input_filter}->get_pending();
    $self->{input_filter}=$new_filter;

    # Updates a closure dealing with the input filter.
    $self->_define_read_state();

    if ( defined($buf) )
    {
        foreach my $cooked_input (@{$new_filter->get($buf)})
        {
            $poe_kernel->yield($self->{event_input}, $cooked_input)
        }
    }
}

# No closures need to be redefined or anything.  All the previously
# put stuff has been serialized already.
sub set_output_filter {
    my($self, $new_filter)=@_;
    $self->{output_filter}=$new_filter;
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
  );

  $wheel->put( $something );
  $wheel->event( ... );

  # To set both the input and output filters at once:
  $wheel->set_filter( new POE::Filter::Something );

  # To set an input filter or an output filter:
  $wheel->set_input_filter( new POE::Filter::Something );
  $wheel->set_output_filter( new POE::Filter::Something );

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

This performs a similar function to the &set_filter method, but it
only changes the input filter.

=item *

POE::Wheel::ReadWrite::set_output_filter( $poe_filter )

This performs a similar function to the &set_filter method, but it
only changes the output filter.

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

=back

=head1 SEE ALSO

POE::Wheel; POE::Wheel::FollowTail; POE::Wheel::ListenAccept;
POE::Wheel::SocketFactory

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
