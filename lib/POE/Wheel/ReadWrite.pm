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

  croak "Handle required" unless (exists $params{'Handle'});
  croak "Driver required" unless (exists $params{'Driver'});
  croak "Filter required" unless (exists $params{'Filter'});

  my $self = bless { 'handle'        => $params{'Handle'},
                     'driver'        => $params{'Driver'},
                     'filter'        => $params{'Filter'},
                     'event input'   => $params{'InputState'},
                     'event error'   => $params{'ErrorState'},
                     'event flushed' => $params{'FlushedState'},
                   }, $type;
                                        # register private event handlers
  $self->_define_read_state();
  $self->_define_write_state();

  $self;
}

#------------------------------------------------------------------------------
# Redefine events.

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'InputState') {
      $self->{'event input'} = $event;
    }
    elsif ($name eq 'ErrorState') {
      $self->{'event error'} = $event;
    }
    elsif ($name eq 'FlushedState') {
      $self->{'event flushed'} = $event;
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
    }
  }

  $self->_define_read_state();
  $self->_define_write_state();
}

#------------------------------------------------------------------------------
# Re/define the read state.  Moved out of new so that it can be redone
# whenever the input and/or error states are changed.

sub _define_read_state {
  my $self = shift;
                                        # stupid closure trick
  my ($event_in, $event_error, $driver, $filter, $handle) =
    @{$self}{'event input', 'event error', 'driver', 'filter', 'handle'};
                                        # register the select-read handler
  if (defined $event_in) {
    $poe_kernel->state
      ( $self->{'state read'} = $self . ' -> select read',
        sub {
                                        # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $driver->get($handle))) {
            foreach my $cooked_input (@{$filter->get($raw_input)}) {
              $k->call($me, $event_in, $cooked_input)
            }
          }
          else {
            $event_error && $k->call($me, $event_error, 'read', ($!+0), $!);
            $k->select_read($handle);
          }
        }
      );
                                        # register the state's select
    $poe_kernel->select_read($handle, $self->{'state read'});
  }
                                        # undefine the select, just in case
  else {
    $poe_kernel->select_read($handle)
  }
}

#------------------------------------------------------------------------------
# Re/define the write state.  Moved out of new so that it can be
# redone whenever the input and/or error states are changed.

sub _define_write_state {
  my $self = shift;
                                        # stupid closure trick
  my ($event_error, $event_flushed, $handle, $driver) =
    @{$self}{'event error', 'event flushed', 'handle', 'driver'};
                                        # register the select-write handler
  $poe_kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $writes_pending = $driver->flush($handle);
        if ($!) {
          $event_error && $k->call($me, $event_error, 'write', ($!+0), $!);
          $k->select_write($handle);
        }
        elsif (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
            (defined $event_flushed) && $k->call($me, $event_flushed);
          }
        }
      }
    );
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->{'handle'});

  if ($self->{'state read'}) {
    $poe_kernel->state($self->{'state read'});
    delete $self->{'state read'};
  }

  if ($self->{'state write'}) {
    $poe_kernel->state($self->{'state write'});
    delete $self->{'state write'};
  }
}

#------------------------------------------------------------------------------

sub put {
  my ($self, @chunks) = @_;
  if ($self->{'driver'}->put($self->{'filter'}->put(\@chunks))) {
    $poe_kernel->select_write($self->{'handle'}, $self->{'state write'});
  }
}

#------------------------------------------------------------------------------
# Redefine filter.  -PG
sub set_filter
{
    my($self, $filter)=@_;
    my $buf=$self->{filter}->get_pending();
    $self->{filter}=$filter;
    $self->_define_read_state();
    $self->_define_write_state();
    if ( defined($buf) )
    {
        foreach my $cooked_input (@{$filter->get($buf)})
        {
            $poe_kernel->yield($self->{'event input'}, $cooked_input)
        }
    }
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ReadWrite - POE Read/Write Logic Abstraction

=head1 SYNOPSIS

  $wheel = new POE::Wheel::ReadWrite(
    Handle       => $file_or_socket_handle,       # Handle to read and write
    Driver       => new POE::Driver::Something(), # Driver to read/write with
    Filter       => new POE::Filter::Something(), # Filter to parse with
    InputState   => $input_state_name,  # Input received state
    FlushedState => $flush_state_name,  # Output flushed state
    ErrorState   => $error_state_name,  # Error occurred state
  );

  $wheel->put( $something );
  $wheel->event( ... );
  $wheel->set_filter( new POE::Filter::Something );

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

POE::Wheel::ReadWrite::set_filter( new POE::Filter::Something() )

The set_filter method changes the filter that the ReadWrite wheel uses
to translate between streams and logical chunks of data.  It uses
filters' get_pending() method to preserve any buffered data between
the previous and new filters.

Please be aware that this method has complex and perhaps non-obvious
side effects.  The description of POE::Filter::get_pending() discusses
them further.

POE::Filter::HTTPD does not support the get_pending() method.
Switching from an HTTPD filter to another one will display a reminder.

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
    # This frees the wheel's resources, including the filehandle,
    # and closes the connection.
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
