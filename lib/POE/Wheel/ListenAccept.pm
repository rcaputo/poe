# $Id$

package POE::Wheel::ListenAccept;

use strict;
use Carp;
use Symbol;

use POSIX qw(fcntl_h errno_h);
use POE qw(Wheel);

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel" unless defined $poe_kernel;

  croak "Handle required"      unless defined $params{Handle};
  croak "AcceptState required" unless defined $params{AcceptState};

  my $self = bless { handle        => $params{Handle},
                     event_accept  => $params{AcceptState},
                     event_error   => $params{ErrorState},
                     unique_id     => &POE::Wheel::allocate_wheel_id(),
                   }, $type;
                                        # register private event handlers
  $self->_define_accept_state();
  $poe_kernel->select($self->{handle}, $self->{state_accept});

  $self;
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'AcceptState') {
      if (defined $event) {
        $self->{event_accept} = $event;
      }
      else {
        carp "AcceptState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->{event_error} = $event;
    }
    else {
      carp "ignoring unknown ListenAccept parameter '$name'";
    }
  }

  $self->_define_accept_state();
}

#------------------------------------------------------------------------------

sub _define_accept_state {
  my $self = shift;
                                        # stupid closure trick
  my $event_accept = \$self->{event_accept};
  my $event_error  = \$self->{event_error};
  my $handle       = $self->{handle};
                                        # register the select-read handler
  $poe_kernel->state
    ( $self->{state_accept} =  $self . ' select read',
      sub {
        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');

        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym;
        my $peer = accept($new_socket, $handle);

        if ($peer) {
          $k->call($me, $$event_accept, $new_socket, $peer);
        }
        elsif ($! != EWOULDBLOCK) {
          $$event_error &&
            $k->call($me, $$event_error, 'accept', ($!+0), $!);
        }
      }
    );
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->{handle});

  if ($self->{state_accept}) {
    $poe_kernel->state($self->{state_accept});
    delete $self->{state_accept};
  }

  &POE::Wheel::free_wheel_id($self->{unique_id});
}

#------------------------------------------------------------------------------

sub ID {
  return $_[0]->{unique_id};
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ListenAccept - POE Listen/Accept Logic Abstraction

=head1 SYNOPSIS

  $wheel = new POE::Wheel::ListenAccept(
    Handle      => $socket_handle,      # Listening socket
    AcceptState => $accept_state_name,  # Success state
    ErrorState  => $error_state_name,   # Failure state
  );

  $wheel->event( AcceptState => $new_state_name ); # Add/change state
  $wheel->event( ErrorState  => undef );           # Remove state

=head1 DESCRIPTION

ListenAccept waits for activity on a listening socket and accepts
remote connections as they arrive.  It generates events for successful
and failed connections (EAGAIN is not considered to be a failure).

This wheel neither needs nor includes a put() method.

ListenAccept is a good way to listen on sockets from other sources,
such as IO::Socket or plain socket() calls.

=head1 PUBLIC METHODS

=over 4

=item *

POE::Wheel::ListenAccept::event( ... )

The event() method changes the events that a ListenAccept wheel emits
for different conditions.  It accepts a list of event types and
values.  Defined state names change the previous values.  Undefined
ones turn off the given condition's events.

For example, this event() call changes a wheel's AcceptState event and
turns off its ErrorState event.

  $wheel->event( AcceptState => $new_accept_state_name,
                 ErrorState  => undef
               );

=item *

POE::Wheel::ListenAccept::ID()

Returns the ListenAccept wheel's unique ID.  This can be used to
associate the wheel's events back to the wheel itself.

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item *

AcceptState

The AcceptState event contains the name of the state that will be
called when a new connection has been accepted.

The ARG0 parameter contains the accepted connection's new socket
handle.

ARG1 contains C<accept()>'s return value.

A sample AcceptState state:

  sub accept_state {
    my $accepted_handle = $_[ARG0];
    # Optional security things with getpeername might go here.
    &create_server_session($handle);
  }

=item *

ErrorState

The ErrorState event contains the name of the state that will be
called when a socket error occurs.  The ListenAccept wheel knows what
to do with EAGAIN, so it's not considered an error worth reporting.

The ARG0 parameter contains the name of the function that failed.
This usually is 'accept'.  ARG1 and ARG2 contain the numeric and
string versions of $! at the time of the error, respectively.

A sample ErrorState state:

  sub error_state {
    my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
    warn "$operation error $errnum: $errstr\n";
  }

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
