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

  croak "Driver required" unless (exists $params{Driver});
  croak "Filter required" unless (exists $params{Filter});

  my $self = bless { input_handle  => $in_handle,
                     output_handle => $out_handle,
                     driver        => $params{Driver},
                     filter        => $params{Filter},
                     event_input   => $params{InputState},
                     event_error   => $params{ErrorState},
                     event_flushed => $params{FlushedState},
                   }, $type;
                                        # register private event handlers
  if (defined $self->{event_input}) {
    $poe_kernel->state
      ( $self->{state_read} = $self . ' -> select read',
        sub {
                                        # prevents SEGV
          0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
          if (defined(my $raw_input = $self->{driver}->get($handle))) {
            foreach my $cooked_input (@{$self->{filter}->get($raw_input)}) {
              $k->call($me, $self->{event_input}, $cooked_input)
            }
          }
          else {
            $self->{event_error} &&
              $k->call($me, $self->{event_error}, 'read', ($!+0), $!);
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
                                        # register the select-write handler
  $poe_kernel->state
    ( $self->{state_write} = $self . ' -> select write',
      sub {                             # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $writes_pending = $self->{driver}->flush($handle);
        if ($!) {
          $self->{event_error} &&
            $k->call($me, $self->{event_error}, 'write', ($!+0), $!);
          $k->select_write($handle);
        }
        elsif (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
            (defined $self->{event_flushed}) &&
              $k->call($me, $self->{event_flushed});
          }
        }
      }
    );

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
      $self->{event_input} = $event;
    }
    elsif ($name eq 'ErrorState') {
      $self->{event_error} = $event;
    }
    elsif ($name eq 'FlushedState') {
      $self->{event_flushed} = $event;
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
    }
  }
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
  if ($self->{driver}->put($self->{filter}->put(\@chunks))) {
    $poe_kernel->select_write($self->{output_handle}, $self->{state_write});
  }
}

#------------------------------------------------------------------------------
# Redefine filter.  -PG
sub set_filter
{
    my($self, $filter)=@_;
    my $buf=$self->{filter}->get_pending();
    $self->{filter}=$filter;
    if ( defined($buf) )
    {
        foreach my $cooked_input (@{$filter->get($buf)})
        {
            $poe_kernel->yield($self->{event_input}, $cooked_input)
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

    # To read and write from the same handle, such as a socket, use
    # the Handle parameter:
    Handle       => $file_or_socket_handle,       # Handle to read/write

    # To read and write from different handles, such as a dual pipe to
    # a child process, or a console, use InputHandle and OutputHandle:
    InputHandle  => $readable_filehandle,         # Handle to read
    OutputHandle => $writable_filehandle,         # Handle to write

    Driver       => new POE::Driver::Something(), # How to read/write it
    Filter       => new POE::Filter::Something(), # How to parse it
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

POE::Wheel::ReadWrite::set_filter( $poe_filter )

The set_filter method changes the filter that the ReadWrite wheel uses
to translate between streams and logical chunks of data.  It uses
filters' get_pending() method to preserve any buffered data between
the previous and new filters.

Please be aware that this method has complex and perhaps non-obvious
side effects.  The description of POE::Filter::get_pending() discusses
them further.

POE::Filter::HTTPD does not support the get_pending() method.
Switching from an HTTPD filter to another one will display a reminder
that it sn't supported.

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
