# $Id$

package POE::Wheel::SocketFactory;

use strict;
use Carp;
use Symbol;

use POSIX qw(fcntl_h errno_h);
use Socket;
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub condition_handle {
  my ($self, $handle, $reuse) = @_;
                                        # fix DOSISHness
  binmode($handle);
                                        # do it the Win32 way (XXX incomplete!)
  if ($^O eq 'MSWin32') {
    my $set_it = "1";
                                        # 126 is FIONBIO
    ioctl($handle, 126 | (ord('f')<<8) | (4<<16) | 0x80000000, $set_it)
      or return ['ioctl', $!+0, $!];
  }
                                        # do it the way everyone else does
  else {
    my $flags = fcntl($handle, F_GETFL, 0)
      or return ['fcntl', $!+0, $!];
    $flags = fcntl($handle, F_SETFL, $flags | O_NONBLOCK)
      or return ['fcntl', $!+0, $!];
  }
                                        # reuse the address, maybe
  setsockopt($handle, SOL_SOCKET, SO_REUSEADDR, $reuse)
    or return ['setsockopt', $!+0, $!];

  return undef;
}

#------------------------------------------------------------------------------
# translate Unix addresses to system-dependent representation, if necessary

sub condition_unix_address {
  my ($address) = @_;
                                        # OS/2 wants backwhacks and \socket\...
  if ($^O eq 'os2') {
    $address =~ tr[\\][/];
    if ($address !~ m{^/socket/}) {
      $address =~ s{^/?}{/socket/};
    }
    $address =~ tr[/][\\];
  }

  $address;
}

#------------------------------------------------------------------------------

sub _define_accept_state {
  my $self = shift;

  $poe_kernel->state
    ( $self->{'state accept'} = $self . ' -> select accept',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym;
        my $peer = accept($new_socket, $handle);

        if ($peer) {
          my ($peer_addr, $peer_port);
          if ( ($self->{'socket domain'} == AF_UNIX) ||
               ($self->{'socket domain'} == PF_UNIX)
          ) {
            $peer_addr = $peer_port = undef;
          }
          elsif ( ($self->{'socket domain'} == AF_INET) ||
                  ($self->{'socket domain'} == PF_INET)
          ) {
            ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
          }
          else {
            die "sanity failure: socket domain == $self->{'socket domain'}";
          }
          $k->call($me, $self->{'event success'},
                   $new_socket, $peer_addr, $peer_port
                  );
        }
        elsif ($! != EWOULDBLOCK) {
          $self->{'event failure'} &&
            $k->call($me, $self->{'event failure'}, 'accept', ($!+0), $!);
        }
      }
    );

  $poe_kernel->select_read($self->{handle}, $self->{'state accept'});
}

#------------------------------------------------------------------------------

sub _define_connect_state {
  my $self = shift;

  $poe_kernel->state
    ( $self->{'state noconnect'} = $self . ' -> select noconnect',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
        $k->select($handle);
                                        # acquire and dispatch connect error
        if (defined $self->{'event failure'}) {
          $! = 0;
          my $error = unpack('i', getsockopt($handle, SOL_SOCKET, SO_ERROR));
          $error && ($! = $error);

          # Old style ignored the fact that sometimes connect states
          # are ready for read on purpose.
          # sysread($handle, my $buf = '', 1);
          # $k->call($me, $failure_event, 'connect', ($!+0), $!);

          if ($!) {
            $k->call($me, $self->{'event failure'}, 'connect', ($!+0), $!);
          }
        }
      }
    );

  $poe_kernel->state
    ( $self->{'state connect'} = $self . ' -> select connect',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        $k->select($handle);

        my $peer = getpeername($handle);
        my ($peer_addr, $peer_port);

        if ( ($self->{'socket domain'} == AF_UNIX) ||
             ($self->{'socket domain'} == PF_UNIX)
        ) {
          $peer_addr = unpack_sockaddr_un($peer);
          $peer_port = undef;
        }
        elsif ( ($self->{'socket domain'} == AF_INET) ||
                ($self->{'socket domain'} == PF_INET)
        ) {
          ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
        }
        else {
          die "sanity failure: socket domain == $self->{'socket domain'}";
        }
        $k->call( $me, $self->{'event success'},
                  $handle, $peer_addr, $peer_port
                );
      }
    );

  $poe_kernel->select($self->{handle},
                      $self->{'state noconnect'},
                      $self->{'state connect'}
                     );
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'SuccessState') {
      if (defined $event) {
        if (ref($event) eq 'CODE') {
          $poe_kernel->state
            ( $self->{'event success'} =
                $self->{state_success} = $self . ' -> success',
              $event
            );
        }
        else {
          if (ref($event) ne '') {
            carp "Strange reference used as SuccessState event";
          }
          $self->{'event success'} = $event;
        }
      }
      else {
        carp "SuccessState requires an event name or coderef.  ignoring undef";
      }
    }
    elsif ($name eq 'FailureState') {
      if (defined $event) {
        if (ref($event) eq 'CODE') {
          $poe_kernel->state
            ( $self->{'event failure'} =
                $self->{state_failure} = $self . ' -> failure',
              $event
            );
        }
        else {
          if (ref($event) ne '') {
            carp "Strange reference used as FailureState event (ignored)"
          }
          $self->{'event failure'} = $event;
        }
      }
      else {
        carp "FailureState requires an event name or coderef.  ignoring undef";
      }
    }
    else {
      carp "ignoring unknown SocketFactory parameter '$name'";
    }
  }

  if (exists $self->{'state accept'}) {
    $poe_kernel->select_read($self->{'handle'}, $self->{'state accept'});
  }
  elsif (exists $self->{'state connect'}) {
    $poe_kernel->select($self->{'handle'},
                        $self->{'state noconnect'},
                        $self->{'state connect'}
                       );
  }
  else {
    die "POE developer error - no state defined";
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

  croak 'SuccessState required' unless (exists $params{'SuccessState'});
  croak 'FailureState required' unless (exists $params{'FailureState'});

  $params{'SocketDomain'} = AF_INET
    unless (exists $params{'SocketDomain'});
  $params{'SocketType'} = SOCK_STREAM
    unless (exists $params{'SocketType'});

  my $self = bless { }, $type;
  my $socket_handle = gensym;

  my ($socket_domain, $socket_type, $success_event, $failure_event)
    = @params{ 'SocketDomain', 'SocketType', 'SuccessState', 'FailureState'};

  $self->{'socket domain'} = $socket_domain;

  if (($socket_domain == AF_UNIX) || ($socket_domain == PF_UNIX)) {

    carp 'SocketProtocol ignored' if (exists $params{'SocketProtocol'});
    carp 'BindPort ignored'       if (exists $params{'BindPort'});
    carp 'RemotePort ignored'     if (exists $params{'RemotePort'});

    unless (socket($socket_handle, $socket_domain, $socket_type, PF_UNSPEC)) {
      $poe_kernel->yield($failure_event, 'socket', $!+0, $!);
      return undef;
    }

    if (defined(my $ret = $self->condition_handle
                ( $socket_handle,
                  (exists $params{'Reuse'}) ? ((!!$params{'Reuse'})+0) : 0
                )
               )
    ) {
      $poe_kernel->yield($failure_event, @$ret);
      close($socket_handle);
      return undef;
    }

    if (exists $params{'BindAddress'}) {
      croak 'BindAddress exists' if (-e $params{'BindAddress'});
      my $bind_address = &condition_unix_address($params{'BindAddress'});
      my $socket_address = sockaddr_un($bind_address);
      unless ($socket_address) {
        $poe_kernel->yield($failure_event, 'sockaddr_un', $!+0, $!);
        close($socket_handle);
        return undef;
      }

      unless (bind($socket_handle, $socket_address)) {
        $poe_kernel->yield($failure_event, 'bind', $!+0, $!);
        close($socket_handle);
        return undef;
      }
    }
                                        # BindAddress is required for DGRAM
    elsif ($params{'SocketType'} eq SOCK_DGRAM) {
      croak 'BindAddress required for Unix datagram socket';
    }

    carp 'RemotePort ignored' if (exists $params{'RemotePort'});

    if (exists $params{RemoteAddress}) {
      my $remote_address =
        condition_unix_address($params{'RemoteAddress'});
      my $socket_address = sockaddr_un($remote_address);
      unless ($socket_address) {
        $poe_kernel->yield($failure_event, 'sockaddr_un', $!+0, $!);
        close $socket_handle;
        return undef;
      }

      unless (connect($socket_handle, $socket_address)) {
        if ($! && ($! != EINPROGRESS)) {
          $poe_kernel->yield($failure_event, 'connect', $!+0, $!);
          close($socket_handle);
          return undef;
        }
      }

      $self->{'handle'} = $socket_handle;
      $self->_define_connect_state();
    }
    else {
      croak "Must bind a Unix server socket"
        unless (exists $params{'BindAddress'});
      my $listen_queue = $params{'ListenQueue'} || SOMAXCONN;
      ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);

      unless (listen($socket_handle, $listen_queue)) {
        $poe_kernel->yield($failure_event, 'listen', $!+0, $!);
        close($socket_handle);
        return undef;
      }

      $self->{'handle'} = $socket_handle;
      $self->_define_accept_state();
    }
  }

  elsif (($socket_domain == AF_INET) || ($socket_domain == PF_INET)) {

    $params{'SocketProtocol'} = 'tcp'
      unless (exists $params{'SocketProtocol'});

    my $socket_protocol = $params{'SocketProtocol'};

    if ($socket_protocol !~ /^\d+$/) {
      unless ($socket_protocol = getprotobyname($socket_protocol)) {
        $poe_kernel->yield($failure_event, 'getprotobyname', $!+0, $!);
        return undef;
      }
    }

    my $protocol_name = getprotobynumber($socket_protocol);
    unless ($protocol_name) {
      $poe_kernel->yield($failure_event, 'getprotobynumber', $!+0, $!);
      return undef;
    }

    if ($protocol_name !~ /^(tcp|udp)$/) {
      croak "Internet sockets only support tcp and udp, not $protocol_name";
    }

    unless (
      socket($socket_handle, $socket_domain, $socket_type, $socket_protocol)
    ) {
      $poe_kernel->yield($failure_event, 'socket', $!+0, $!);
      return undef;
    }

    if (defined(my $ret = $self->condition_handle
                ( $socket_handle,
                  (exists $params{'Reuse'}) ? ((!!$params{'Reuse'})+0) : 0
                )
               )
    ) {
      $poe_kernel->yield($failure_event, @$ret);
      close($socket_handle);
      return undef;
    }
                                        # bind this side of the socket
    my ($bind_address, $bind_port);
    if (exists $params{'BindAddress'}) {
      $bind_address = $params{'BindAddress'};
      (length($bind_address) != 4) &&
        ($bind_address = inet_aton($bind_address));
      unless (defined $bind_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield($failure_event, 'inet_aton', $!+0, $!);
        close $socket_handle;
        return undef;
      }
    }
    else {
      $bind_address = INADDR_ANY;
    }

    if (exists $params{'BindPort'}) {
      $bind_port = $params{'BindPort'};
      if ($bind_port !~ /^\d+$/) {
        $bind_port = getservbyname($bind_port, $protocol_name);
      }
    }
    else {
      $bind_port = 0;
    }

    my $packed_bind_address = sockaddr_in($bind_port, $bind_address);
    unless ($packed_bind_address) {
      $poe_kernel->yield($failure_event, 'sockaddr_in', $!+0, $!);
      close $socket_handle;
      return undef;
    }

    unless (bind($socket_handle, $packed_bind_address)) {
      $poe_kernel->yield($failure_event, 'bind', $!+0, $!);
      close($socket_handle);
      return undef;
    }

    if ($protocol_name eq 'tcp') {
                                        # connecting if RemoteAddress
      if (exists $params{RemoteAddress}) {
        croak 'RemotePort required' unless (exists $params{'RemotePort'});
        carp 'ListenQueue ignored' if (exists $params{'ListenQueue'});

        my $remote_port = $params{'RemotePort'};
        if ($remote_port !~ /^\d+$/) {
          unless ($remote_port = getservbyname($remote_port, $protocol_name)) {
            $poe_kernel->yield($failure_event, 'getservbyname', $!+0, $!);
            close($socket_handle);
            return undef;
          }
        }

        my $remote_address = inet_aton($params{'RemoteAddress'});
        unless (defined $remote_address) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield($failure_event, 'inet_aton', $!+0, $!);
          close($socket_handle);
          return undef;
        }

        my $packed_connect_address =
          sockaddr_in($remote_port, $remote_address);
        unless ($packed_connect_address) {
          $poe_kernel->yield($failure_event, 'sockaddr_in', $!+0, $!);
          close $socket_handle;
          return undef;
        }

        unless (connect($socket_handle, $packed_connect_address)) {
          if ($! && ($! != EINPROGRESS)) {
            $poe_kernel->yield($failure_event, 'connect', $!+0, $!);
            close($socket_handle);
            return undef;
          }
        }

        $self->{'handle'} = $socket_handle;
        $self->_define_connect_state();
      }
                                        # listening if no RemoteAddress
      else {
        my $listen_queue = $params{'ListenQueue'} || SOMAXCONN;
        ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);

        unless (listen($socket_handle, $listen_queue)) {
          $poe_kernel->yield($failure_event, 'listen', $!+0, $!);
          close($socket_handle);
          return undef;
        }

        $self->{'handle'} = $socket_handle;
        $self->_define_accept_state();
      }
    }
    elsif ($protocol_name eq 'udp') {
      die 'udp inet socket not implemented';
    }
    else {
      croak "Internet sockets only support tcp and udp, not $protocol_name";
    }
  }

  else {
    croak 'unsupported SocketDomain';
  }

  $self->event( SuccessState => $params{'SuccessState'},
                FailureState => $params{'FailureState'},
              );

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  if (exists $self->{'handle'}) {
    $poe_kernel->select($self->{'handle'});
  }

  if (exists $self->{'state accept'}) {
    $poe_kernel->state($self->{'state accept'});
    delete $self->{'state accept'};
  }

  if (exists $self->{'state connect'}) {
    $poe_kernel->state($self->{'state connect'});
    delete $self->{'state connect'};
  }

  if (exists $self->{'state noconnect'}) {
    $poe_kernel->state($self->{'state noconnect'});
    delete $self->{'state noconnect'};
  }

  if (exists $self->{state_success}) {
    $poe_kernel->state($self->{state_success});
    delete $self->{state_success};
  }

  if (exists $self->{state_failure}) {
    $poe_kernel->state($self->{state_failure});
    delete $self->{state_failure};
  }
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::SocketFactory - POE Socket Creation Logic Abstraction

=head1 SYNOPSIS

  use Socket; # For the constants

  # Listening Unix domain socket.
  $wheel = new POE::Wheel::SocketFactory(
    SocketDomain => AF_UNIX,               # Sets the socket() domain
    BindAddress  => $unix_socket_address,  # Sets the bind() address
    SuccessState => $success_state,        # State to call upon accept()
    FailureState => $failure_state,        # State to call upon error
    # Optional parameters (and default values):
    SocketType   => SOCK_STREAM,           # Sets the socket() type
  );

  # Connecting Unix domain socket.
  $wheel = new POE::Wheel::SocketFactory(
    SocketDomain  => AF_UNIX,              # Sets the socket() domain
    RemoteAddress => $unix_server_address, # Sets the connect() address
    SuccessState  => $success_state,       # State to call on connection
    FailureState  => $failure_state,       # State to call on error
    # Optional parameters (and default values):
    SocketType    => SOCK_STREAM,          # Sets the socket() type
    # Optional parameters (that have no defaults):
    BindAddress   => $unix_client_address, # Sets the bind() address
  );

  # Listening Internet domain socket.
  $wheel = new POE::Wheel::SocketFactory(
    BindAddress    => $inet_address,       # Sets the bind() address
    BindPort       => $inet_port,          # Sets the bind() port
    SuccessState   => $success_state,      # State to call upon accept()
    FailureState   => $failure_state,      # State to call upon error
    # Optional parameters (and default values):
    SocketDomain   => AF_INET,             # Sets the socket() domain
    SocketType     => SOCK_STREAM,         # Sets the socket() type
    SocketProtocol => 'tcp',               # Sets the socket() protocol
    ListenQueue    => SOMAXCONN,           # The listen() queue length
    Reuse          => 'no',                # Lets the port be reused
  );

  # Connecting Internet domain socket.
  $wheel = new POE::Wheel::SocketFactory(
    RemoteAddress  => $inet_address,       # Sets the connect() address
    RemotePort     => $inet_port,          # Sets the connect() port
    SuccessState   => $success_state,      # State to call on connection
    FailureState   => $failure_state,      # State to call on error
    # Optional parameters (and default values):
    SocketDomain   => AF_INET,             # Sets the socket() domain
    SocketType     => SOCK_STREAM,         # Sets the socket() type
    SocketProtocol => 'tcp',               # Sets the socket() protocol
    Reuse          => 'no',                # Lets the port be reused
  );

  $wheel->event( ... );

=head1 DESCRIPTION

This wheel creates sockets, generating events when something happens
to them.  Success events come with connected, ready to use sockets.
Failure events are accompanied by error codes, similar to other
wheels'.

SocketFactory currently supports Unix domain sockets, and TCP sockets
within the Internet domain.  Other protocols are forthcoming,
eventually; let the author or mailing list know if they're needed
sooner.

=head1 PUBLIC METHODS

=over 4

=item *

POE::Wheel::SocketFactory::new()

The new() method does most of the work.  It has parameters for just
about every aspect of socket creation: socket(), setsockopt(), bind(),
listen(), connect() and accept().  Thankfully they all aren't used at
the same time.

The parameters:

=over 2

=item *

SocketDomain

SocketDomain is the DOMAIN parameter for the socket() call.  Currently
supported values are AF_UNIX, AF_INET, PF_UNIX and PF_INET.  It
defaults to AF_INET if omitted.

=item *

SocketType

SocketType is the TYPE parameter for the socket() call.  Currently
supported values are SOCK_STREAM and SOCK_DGRAM (although datagram
sockets aren't tested at this time).  It defaults to SOCK_STREAM if
omitted.

=item *

SocketProtocol

SocketProtocol is the PROTOCOL parameter for the socket() call.
Protocols may be specified by name or number (see /etc/protocols, or
the equivalent file).  The only supported protocol at this time is
'tcp'.  SocketProtocol is ignored for Unix domain sockets.  It
defaults to 'tcp' if omitted from an Internet socket constructor.

=item *

BindAddress

BindAddress is the local interface address that the socket will be
bound to.

For Internet domain sockets: The bind address may be a string
containing a dotted quad, a host name, or a packed Internet address
(without the port).  It defaults to INADDR_ANY if it's not specified,
which will try to bind the socket to every interface.  If any
interface has a socket already bound to the BindPort, then bind() (and
the SocketFactory) will fail.

For Unix domain sockets: The bind address is a path where the socket
will be created.  It is required for server sockets and datagram
client sockets.  If a file exists at the bind address, then bind()
(and the SocketFactory) will fail.

=item *

BindPort

BindPort is the port of the local interface(s) that the socket will
try to bind to.  It is ignored for Unix sockets and recommended for
Internet sockets.  It defaults to 0 if omitted, which will bind the
socket to an unspecified available port.

The bind port may be a number, or a name in the /etc/services (or
equivalent) database.

=item *

ListenQueue

ListenQueue specifies the length of the socket's listen() queue.  It
defaults to SOMAXCONN if omitted.  SocketFactory will ensure that
ListenQueue doesn't exceed SOMAXCONN.

It should go without saying that ListenQueue is only appropriate for
listening sockets.

=item *

RemoteAddress

RemoteAddress is the remote address to which the socket should
connect.  If present, the SocketFactory will create a connecting
socket; otherwise, the SocketFactory will make a listening socket.

The remote address may be a string containing a dotted quad, a host
name, a packed Internet address, or a Unix socket path.  It will be
packed, with or without an accompanying RemotePort as necessary for
the socket domain.

=item *

RemotePort

RemotePort is the port to which the socket should connect.  It is
required for connecting Internet sockets and ignored in all other
cases.

The remote port may be a number, or a name in the /etc/services (or
equivalent) database.

=back

=item *

POE::Wheel::SocketFactory::event(...)

Please see POE::Wheel.

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item *

SuccessState

The SuccessState parameter defines a state name or coderef to call
upon a successful connect or accept.  The operation it succeeds on
depends on the type of socket created.

For connecting sockets, the success state/coderef is called when the
socket has connected.  For listening sockets, the success
state/coderef is called for each successfully accepted client
connection.

ARG0 contains the connected or accepted socket.

For INET sockets, ARG1 and ARG2 hold the socket's remote address and
port, respectively.

For Unix client sockets, ARG1 contains the server address and ARG2 is
undefined.

According to _Perl Cookbook_, the remote address for accepted Unix
domain sockets is undefined.  So ARG0 and ARG1 are, too.

=item *

FailureState

The FailureState parameter defines a state name or coderef to call
when a socket error occurs.  The SocketFactory knows what to do with
EAGAIN, so that's not considered an error.

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
POE::Wheel::ReadWrite; POE::Wheel::SocketFactory

=head1 BUGS

No connectionless sockets yet.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
