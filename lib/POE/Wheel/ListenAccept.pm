# $Id$

package POE::Wheel::ListenAccept;

use strict;
use Carp;
use POSIX qw(EAGAIN);
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

  croak "Handle required"      unless (exists $params{'Handle'});
  croak "AcceptState required" unless (exists $params{'AcceptState'});

  my $self = bless { 'handle'       => $params{'Handle'},
                     'event accept' => $params{'AcceptState'},
                     'event error'  => $params{'ErrorState'},
                   }, $type;
                                        # register private event handlers
  $self->_define_accept_state();
  $poe_kernel->select($self->{'handle'}, $self->{'state read'});

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
        $self->{'event accept'} = $event;
      }
      else {
        carp "AcceptState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->{'event error'} = $event;
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
  my ($event_accept, $event_error, $handle) =
    @{$self}{'event accept', 'event error', 'handle'};
                                        # register the select-read handler
  $poe_kernel->state
    ( $self->{'state read'} =  $self . ' -> select read',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = $handle->accept();

        if ($new_socket) {
          $k->call($me, $event_accept, $new_socket);
        }
        elsif ($! != EAGAIN) {
          $event_error &&
            $k->call($me, $event_error, 'accept', ($!+0), $!);
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

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item *

AcceptState

The AcceptState event contains the name of the state that will be
called when a new connection has been accepted.

The ARG0 parameter contains the accepted connection's new socket
handle.

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

POE::Wheel; POE::Wheel::FollowTail; POE::Wheel::ReadWrite;
POE::Wheel::SocketFactory

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
