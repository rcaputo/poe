# $Id$

package POE::Wheel::ListenAccept;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use Carp;
use Symbol;

use POSIX qw(fcntl_h errno_h);
use POE qw(Wheel);

sub SELF_HANDLE       () { 0 }
sub SELF_EVENT_ACCEPT () { 1 }
sub SELF_EVENT_ERROR  () { 2 }
sub SELF_UNIQUE_ID    () { 3 }
sub SELF_STATE_ACCEPT () { 4 }

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel" unless defined $poe_kernel;

  # STATE-EVENT
  if (exists $params{AcceptState}) {
    croak "AcceptState is deprecated.  Use AcceptEvent";
  }

  # STATE-EVENT
  if (exists $params{ErrorState}) {
    croak "ErrorState is deprecated.  Use ErrorEvent";
  }

  croak "Handle required"      unless defined $params{Handle};
  croak "AcceptEvent required" unless defined $params{AcceptEvent};

  my $self = bless [ $params{Handle},                  # SELF_HANDLE
                     delete $params{AcceptEvent},      # SELF_EVENT_ACCEPT
                     delete $params{ErrorEvent},       # SELF_EVENT_ERROR
                     &POE::Wheel::allocate_wheel_id(), # SELF_UNIQUE_ID
                     undef,                            # SELF_STATE_ACCEPT
                   ], $type;
                                        # register private event handlers
  $self->_define_accept_state();
  $poe_kernel->select($self->[SELF_HANDLE], $self->[SELF_STATE_ACCEPT]);

  $self;
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    # STATE-EVENT
    if ($name =~ /^(.*?)State$/) {
      croak "$name is deprecated.  Use $1Event";
    }

    if ($name eq 'AcceptEvent') {
      if (defined $event) {
        $self->[SELF_EVENT_ACCEPT] = $event;
      }
      else {
        carp "AcceptEvent requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorEvent') {
      $self->[SELF_EVENT_ERROR] = $event;
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
  my $event_accept = \$self->[SELF_EVENT_ACCEPT];
  my $event_error  = \$self->[SELF_EVENT_ERROR];
  my $handle       = $self->[SELF_HANDLE];
  my $unique_id    = $self->[SELF_UNIQUE_ID];
                                        # register the select-read handler
  $poe_kernel->state
    ( $self->[SELF_STATE_ACCEPT] =  ref($self) . "($unique_id) -> select read",
      sub {
        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');

        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym;
        my $peer = accept($new_socket, $handle);

        if ($peer) {
          $k->call($me, $$event_accept, $new_socket, $peer, $unique_id);
        }
        elsif ($! != EWOULDBLOCK) {
          $$event_error &&
            $k->call($me, $$event_error, 'accept', ($!+0), $!, $unique_id);
        }
      }
    );
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->[SELF_HANDLE]);

  if ($self->[SELF_STATE_ACCEPT]) {
    $poe_kernel->state($self->[SELF_STATE_ACCEPT]);
    undef $self->[SELF_STATE_ACCEPT];
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

POE::Wheel::ListenAccept - accept connections from regular listening sockets

=head1 SYNOPSIS

  $wheel = POE::Wheel::ListenAccept->new(
    Handle      => $socket_handle,      # Listening socket
    AcceptEvent => $accept_event_name,  # Event to emit on successful accept
    ErrorEvent  => $error_event_name,   # Event to emit on some kind of error
  );

  $wheel->event( AcceptEvent => $new_event_name ); # Add/change event
  $wheel->event( ErrorEvent  => undef );           # Remove event

=head1 DESCRIPTION

ListenAccept listens on an already established socket and accepts
remote connections from it as they arrive.  Sockets it listens on can
come from anything that makes filehandles.  This includes socket()
calls and IO::Socket::* instances.

The ListenAccept wheel generates events for successful and failed
connections.  EAGAIN is handled internally, so sessions needn't worry
about it.

This wheel neither needs nor includes a put() method.

=head1 PUBLIC METHODS

=over 2

=item event EVENT_TYPE => EVENT_NAME, ...

event() is covered in the POE::Wheel manpage.

ListenAccept's event types are C<AcceptEvent> and C<ErrorEvent>.

=item ID

The ID method returns a ListenAccept wheel's unique ID.  This ID will
be included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=back

=head1 EVENT TYPES AND THEIR PARAMETERS

These are the event types this wheel emits and the parameters which
are included with each.

=over 2

=item AcceptEvent

An AcceptEvent is generated whenever a new connection has been
successfully accepted.  AcceptEvent is accompanied by three
parameters: C<ARG0> contains the accepted socket handle.  C<ARG1>
contains the accept() call's return value, which often is the address
of the other end of the socket.  C<ARG2> contains the wheel's unique
ID.

A sample AcceptEvent handler:

  sub accept_state {
    my ($accepted_handle, $remote_address, $wheel_id) = @_[ARG0..ARG2];

    # The remote address is always good here.
    my ($port, $packed_ip) = sockaddr_in($remote_address);
    my $dotted_quad = inet_ntoa($packed_ip);

    print( "Wheel $wheel_id accepted a connection from ",
           "$dotted_quad port $port.\n"
         );

    # Spawn off a session to interact with the socket.
    &create_server_session($handle);
  }

=item ErrorEvent

The ErrorEvent event is generated whenever a new connection could not
be successfully accepted.  Its event is accompanied by four
parameters.

C<ARG0> contains the name of the operation that failed.  This usually
is 'accept'.  Note: This is not necessarily a function name.

C<ARG1> and C<ARG2> hold numeric and string values for C<$!>,
respectively.  Note: ListenAccept knows how to handle EAGAIN, so it
will never return that error.

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

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
