# $Id$

package POE::Wheel::SocketFactory;

use strict;
use Carp;
use Symbol;

use POSIX qw(fcntl_h errno_h);
use Socket;
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }
sub DEBUG () { 0 }

#------------------------------------------------------------------------------

sub DOM_UNIX () { 'unix' }
sub DOM_INET () { 'inet' }

my %map_family_to_domain =
  ( AF_UNIX, DOM_UNIX, PF_UNIX, DOM_UNIX,
    AF_INET, DOM_INET, PF_INET, DOM_INET,
  );

sub SVROP_LISTENS () { 'listens' }
sub SVROP_NOTHING () { 'nothing' }

my %supported_protocol =
  ( DOM_UNIX, { none => SVROP_LISTENS },
    DOM_INET, { tcp => SVROP_LISTENS,
                udp => SVROP_NOTHING,
              },
  );

my %default_socket_type =
  ( DOM_UNIX, { none => SOCK_STREAM },
    DOM_INET, { tcp => SOCK_STREAM,
                udp => SOCK_DGRAM,
              },
  );

#------------------------------------------------------------------------------
# Perform system-dependent translations on Unix addresses, if
# necessary.

sub condition_unix_address {
  my ($address) = @_;

  # OS/2 would like sockets to use backwhacks, and please place them
  # in the virtual \socket\ directory.  Thank you.
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
# Define the select handler that will accept connections.

sub _define_accept_state {
  my $self = shift;

  $poe_kernel->state
    ( $self->{state_accept} = $self . ' -> select accept',
      sub {
        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');

        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym;
        my $peer = accept($new_socket, $handle);

        if ($peer) {
          my ($peer_addr, $peer_port);
          if ( ($self->{socket_domain} == AF_UNIX) ||
               ($self->{socket_domain} == PF_UNIX)
          ) {
            $peer_addr = $peer_port = undef;
          }
          elsif ( ($self->{socket_domain} == AF_INET) ||
                  ($self->{socket_domain} == PF_INET)
          ) {
            ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
          }
          else {
            die "sanity failure: socket domain == $self->{socket_domain}";
          }
          $k->call($me, $self->{state_success},
                   $new_socket, $peer_addr, $peer_port
                  );
        }
        elsif ($! != EWOULDBLOCK) {
          $self->{state_failure} &&
            $k->call($me, $self->{state_failure}, 'accept', ($!+0), $!);
        }
      }
    );

  $poe_kernel->select_read($self->{socket_handle}, $self->{state_accept});
}

#------------------------------------------------------------------------------
# Define the select handler that will finalize an established
# connection.

sub _define_connect_state {
  my $self = shift;

  $poe_kernel->state
    ( $self->{state_noconnect} = $self . ' -> select noconnect',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
        $k->select($handle);
                                        # acquire and dispatch connect error
        if (defined $self->{state_failure}) {
          $! = 0;
          my $error = unpack('i', getsockopt($handle, SOL_SOCKET, SO_ERROR));
          $error && ($! = $error);

          # Old style ignored the fact that sometimes connect states
          # are ready for read on purpose.
          # sysread($handle, my $buf = '', 1);
          # $k->call($me, $failure_event, 'connect', ($!+0), $!);

          if ($!) {
            $k->call($me, $self->{state_failure}, 'connect', ($!+0), $!);
          }
        }
      }
    );

  $poe_kernel->state
    ( $self->{state_connect} = $self . ' -> select connect',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        $k->select($handle);

        my $peer = getpeername($handle);
        my ($peer_addr, $peer_port);

        if ( ($self->{socket_domain} == AF_UNIX) ||
             ($self->{socket_domain} == PF_UNIX)
        ) {
          $peer_addr = unpack_sockaddr_un($peer);
          $peer_port = undef;
        }
        elsif ( ($self->{socket_domain} == AF_INET) ||
                ($self->{socket_domain} == PF_INET)
        ) {
          ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
        }
        else {
          die "sanity failure: socket domain == $self->{socket_domain}";
        }
        $k->call( $me, $self->{state_success},
                  $handle, $peer_addr, $peer_port
                );
      }
    );

  $poe_kernel->select($self->{socket_handle},
                      $self->{state_noconnect},
                      $self->{state_connect}
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
            ( $self->{state_success} = $self . ' -> success',
              $event
            );
        }
        else {
          if (ref($event) ne '') {
            carp "Strange reference used as SuccessState event";
          }
          $self->{state_success} = $event;
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
            ( $self->{state_failure} = $self . ' -> failure',
              $event
            );
        }
        else {
          if (ref($event) ne '') {
            carp "Strange reference used as FailureState event (ignored)"
          }
          $self->{state_failure} = $event;
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

  if (exists $self->{state_accept}) {
    $poe_kernel->select_read($self->{socket_handle}, $self->{state_accept});
  }
  elsif (exists $self->{state_connect}) {
    $poe_kernel->select($self->{socket_handle},
                        $self->{state_noconnect},
                        $self->{state_connect}
                       );
  }
  else {
    die "POE developer error - no state defined";
  }
}

#------------------------------------------------------------------------------

sub getsockname {
  my $self = shift;
  return undef unless defined $self->{socket_handle};
  return getsockname($self->{socket_handle});
}

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  # The calling conventio experienced a hard depreciation.
  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  # Ensure some of the basic things are present.
  croak "$type requires a working Kernel" unless (defined $poe_kernel);
  croak 'SuccessState required' unless (exists $params{SuccessState});
  croak 'FailureState required' unless (exists $params{FailureState});
  my $state_success = $params{SuccessState};
  my $state_failure = $params{FailureState};

  # Create the SocketServer.  Cache a copy of the socket handle.
  my $socket_handle = gensym();
  my $self = bless { socket_handle => $socket_handle,
                     state_success => $params{SuccessState},
                     state_failure => $params{FailureState},
                   }, $type;

  # Default to Internet sockets.
  $self->{socket_domain} = ( (exists $params{SocketDomain})
                             ? $params{SocketDomain}
                             : AF_INET
                           );

  # Abstract the socket domain into something we don't have to keep
  # testing duplicates of.
  my $abstract_domain = $map_family_to_domain{$self->{socket_domain}};
  unless (defined $abstract_domain) {
    $poe_kernel->yield($state_failure, 'domain', 0, '');
    return undef;
  }

  #---------------#
  # Create Socket #
  #---------------#

  # Declare the protocol name out here; it'll be needed by
  # getservbyname later.
  my $protocol_name;

  # Unix sockets don't use protocols; warn the programmer, and force
  # PF_UNSPEC.
  if ($abstract_domain eq DOM_UNIX) {
    carp 'SocketProtocol ignored for Unix socket'
      if exists $params{SocketProtocol};
    $self->{socket_protocol} = PF_UNSPEC;
    $protocol_name = 'none';
  }

  # Internet sockets use protocols.  Default the INET protocol to tcp,
  # and try to resolve it.
  elsif ($abstract_domain eq DOM_INET) {
    my $socket_protocol =
      (exists $params{SocketProtocol}) ? $params{SocketProtocol} : 'tcp';

    if ($socket_protocol !~ /^\d+$/) {
      unless ($socket_protocol = getprotobyname($socket_protocol)) {
        $poe_kernel->yield($state_failure, 'getprotobyname', $!+0, $!);
        return undef;
      }
    }

    # Get the protocol's name regardless of what was provided.  If the
    # protocol isn't supported, croak now instead of making the
    # programmer wonder why things fail later.
    $protocol_name = lc(getprotobynumber($socket_protocol));
    unless ($protocol_name) {
      $poe_kernel->yield($state_failure, 'getprotobynumber', $!+0, $!);
      return undef;
    }

    unless (exists $supported_protocol{$abstract_domain}->{$protocol_name}) {
      croak "SocketFactory does not support Internet $protocol_name sockets";
    }

    $self->{socket_protocol} = $socket_protocol;
  }
  else {
    die "Mail this error to the author of POE: Internal consistency error";
  }

  # If no SocketType, default it to something appropriate.
  if (exists $params{SocketType}) {
    $self->{socket_type} = $params{SocketType};
  }
  else {
    unless (exists $default_socket_type{$abstract_domain}->{$protocol_name}) {
      croak "SocketFactory does not support $abstract_domain $protocol_name";
    }
    $self->{socket_type} =
      $default_socket_type{$abstract_domain}->{$protocol_name};
  }

  # Create the socket.
  unless (socket( $socket_handle, $self->{socket_domain},
                  $self->{socket_type}, $self->{socket_protocol}
                )
  ) {
    $poe_kernel->yield($state_failure, 'socket', $!+0, $!);
    return undef;
  }

  DEBUG && warn "socket";

  #------------------#
  # Configure Socket #
  #------------------#

  # Make the socket binary.  This probably is necessary for DOSISH
  # systems, and nothing untoward should happen on sane systems.
  binmode($socket_handle);

  # Don't block on socket operations, because the socket will be
  # driven by a select loop.

  # Do it the Win32 way.  XXX This is incomplete.
  if ($^O eq 'MSWin32') {
    my $set_it = "1";
                                        # 126 is FIONBIO
    ioctl($socket_handle, 126 | (ord('f')<<8) | (4<<16) | 0x80000000, $set_it)
      or do {
        $poe_kernel->yield($state_failure, 'ioctl', $!+0, $!);
        return undef;
      };
  }

  # Do it the way everyone else does.
  else {
    my $flags = fcntl($socket_handle, F_GETFL, 0)
      or do {
        $poe_kernel->yield($state_failure, 'fcntl', $!+0, $!);
        return undef;
      };
    $flags = fcntl($socket_handle, F_SETFL, $flags | O_NONBLOCK)
      or do {
        $poe_kernel->yield($state_failure, 'fcntl', $!+0, $!);
        return undef;
      };
  }

  # Make the socket reusable, if requested.
  if ( (exists $params{Reuse})
       and ( (lc($params{Reuse}) eq 'yes')
             or ( ($params{Reuse} =~ /\d+/)
                  and $params{Reuse}
                )
           )
     )
  {
    setsockopt($socket_handle, SOL_SOCKET, SO_REUSEADDR, 1)
      or do {
        $poe_kernel->yield($state_failure, 'setsockopt', $!+0, $!);
        return undef;
      };
  }

  #-------------#
  # Bind Socket #
  #-------------#

  my $bind_address;

  # Check SocketFactory /Bind.*/ parameters in an Internet socket
  # context, and translate them into parameters that bind()
  # understands.
  if ($abstract_domain eq DOM_INET) {

    # Don't bind if the creator doesn't specify a related parameter.
    if ((exists $params{BindAddress}) or (exists $params{BindPort})) {

      # Set the bind address, or default to INADDR_ANY.
      $bind_address = ( (exists $params{BindAddress})
                        ? $params{BindAddress}
                        : INADDR_ANY
                      );

      # Resolve the bind address if it's not already packed.
      (length($bind_address) == 4)
        or ($bind_address = inet_aton($bind_address));
      unless (defined $bind_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield($state_failure, 'inet_aton', $!+0, $!);
        return undef;
      }

      # Set the bind port, or default to 0 (any) if none specified.
      # Resolve it to a number, if at all possible.
      my $bind_port = (exists $params{BindPort}) ? $params{BindPort} : 0;
      if ($bind_port =~ /[^0-9]/) {
        $bind_port = getservbyname($bind_port, $protocol_name);
        unless (defined $bind_port) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield($state_failure, 'getservbyname', $!+0, $!);
          return undef;
        }
      }

      $bind_address = pack_sockaddr_in($bind_port, $bind_address);
      unless (defined $bind_address) {
        $poe_kernel->yield($state_failure, 'pack_sockaddr_in', $!+0, $!);
        return undef;
      }
    }
  }

  # Check SocketFactory /Bind.*/ parameters in a Unix context, and
  # translate them into parameters bind() understands.
  elsif ($abstract_domain eq DOM_UNIX) {
    carp 'BindPort ignored for Unix socket' if exists $params{BindPort};

    if (exists $params{BindAddress}) {
      # Is this necessary, or will bind() return EADDRINUSE?
      if (exists $params{RemotePort}) {
        $! = EADDRINUSE;
        $poe_kernel->yield($state_failure, 'bind', $!+0, $!);
        return undef;
      }

      $bind_address = &condition_unix_address($params{BindAddress});
      $bind_address = pack_sockaddr_un($bind_address);
      unless ($bind_address) {
        $poe_kernel->yield($state_failure, 'pack_sockaddr_un', $!+0, $!);
        return undef;
      }
    }
  }

  # This is an internal consistency error, and it should be hard
  # trapped right away.
  else {
    die "Mail this error to the author of POE: Internal consistency error";
  }

  # Perform the actual bind, if there's a bind address to bind to.
  if (defined $bind_address) {
    unless (bind($socket_handle, $bind_address)) {
      $poe_kernel->yield($state_failure, 'bind', $!+0, $!);
      return undef;
    }

    DEBUG && warn "bind";
  }

  #---------#
  # Connect #
  #---------#

  my $connect_address;

  if (exists $params{RemoteAddress}) {

    # Check SocketFactory /Remote.*/ parameters in an Internet socket
    # context, and translate them into parameters that connect()
    # understands.
    if ($abstract_domain eq DOM_INET) {
                                        # connecting if RemoteAddress
      croak 'RemotePort required' unless (exists $params{RemotePort});
      carp 'ListenQueue ignored' if (exists $params{ListenQueue});

      my $remote_port = $params{RemotePort};
      if ($remote_port =~ /[^0-9]/) {
        unless ($remote_port = getservbyname($remote_port, $protocol_name)) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield($state_failure, 'getservbyname', $!+0, $!);
          return undef;
        }
      }

      $connect_address = inet_aton($params{RemoteAddress});
      unless (defined $connect_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield($state_failure, 'inet_aton', $!+0, $!);
        return undef;
      }

      $connect_address = pack_sockaddr_in($remote_port, $connect_address);
      unless ($connect_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield($state_failure, 'pack_sockaddr_in', $!+0, $!);
        return undef;
      }
    }

    # Check SocketFactory /Remote.*/ parameters in a Unix socket
    # context, and translate them into parameters connect()
    # understands.
    elsif ($abstract_domain eq DOM_UNIX) {

      $connect_address = condition_unix_address($params{RemoteAddress});
      $connect_address = pack_sockaddr_un($connect_address);
      unless (defined $connect_address) {
        $poe_kernel->yield($state_failure, 'pack_sockaddr_un', $!+0, $!);
        return undef;
      }
    }

    # This is an internal consistency error, and it should be trapped
    # right away.
    else {
      die "Mail this error to the author of POE: Internal consistency error";
    }
  }

  else {
    carp "RemotePort ignored without RemoteAddress"
      if exists $params{RemotePort};
  }

  # Perform the actual connection, if a connection was requested.  If
  # the connection can be established, then return the SocketFactory
  # handle.
  if (defined $connect_address) {
    unless (connect($socket_handle, $connect_address)) {
      if ($! and ($! != EINPROGRESS)) {
        $poe_kernel->yield($state_failure, 'connect', $!+0, $!);
        return undef;
      }
    }

    DEBUG && warn "connect";

    $self->{socket_handle} = $socket_handle;
    $self->_define_connect_state();
    $self->event( SuccessState => $params{SuccessState},
                  FailureState => $params{FailureState},
                );
    return $self;
  }

  #---------------------#
  # Listen, or Whatever #
  #---------------------#

  # A connection wasn't requested, so this must be a server socket.
  # Do whatever it is that needs to be done for whatever type of
  # server socket this is.
  if (exists $supported_protocol{$abstract_domain}->{$protocol_name}) {
    my $protocol_op = $supported_protocol{$abstract_domain}->{$protocol_name};

    DEBUG && warn "$abstract_domain + $protocol_name = $protocol_op";

    if ($protocol_op eq SVROP_LISTENS) {
      my $listen_queue = $params{ListenQueue} || SOMAXCONN;
      ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);
      unless (listen($socket_handle, $listen_queue)) {
        $poe_kernel->yield($state_failure, 'listen', $!+0, $!);
        return undef;
      }

      DEBUG && warn "listen";

      $self->{socket_handle} = $socket_handle;
      $self->_define_accept_state();
      $self->event( SuccessState => $params{SuccessState},
                    FailureState => $params{FailureState},
                  );
      return $self;
    }
    else {
      carp "Ignoring ListenQueue parameter for non-listening socket"
        if exists $params{ListenQueue};
      if ($protocol_op eq SVROP_NOTHING) {
        # Do nothing.  Duh.  Fire off a success event immediately, and
        # return.
        $poe_kernel->yield($state_success, $socket_handle, undef, undef);
      return $self;
      }
      else {
        die "Mail this error to the author of POE: Internal consistency error";
      }
    }
  }
  else {
    die "SocketFactory doesn't support $abstract_domain $protocol_name socket";
  }

  die "Mail this error to the author of POE: Internal consistency error";
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  if (exists $self->{socket_handle}) {
    $poe_kernel->select($self->{socket_handle});
  }

  if (exists $self->{state_accept}) {
    $poe_kernel->state($self->{state_accept});
    delete $self->{state_accept};
  }

  if (exists $self->{state_connect}) {
    $poe_kernel->state($self->{state_connect});
    delete $self->{state_connect};
  }

  if (exists $self->{state_noconnect}) {
    $poe_kernel->state($self->{state_noconnect});
    delete $self->{state_noconnect};
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
    FailureState => $state_failure,        # State to call upon error
    # Optional parameters (and default values):
    SocketType   => SOCK_STREAM,           # Sets the socket() type
  );

  # Connecting Unix domain socket.
  $wheel = new POE::Wheel::SocketFactory(
    SocketDomain  => AF_UNIX,              # Sets the socket() domain
    RemoteAddress => $unix_server_address, # Sets the connect() address
    SuccessState  => $success_state,       # State to call on connection
    FailureState  => $state_failure,       # State to call on error
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
    FailureState   => $state_failure,      # State to call upon error
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
    FailureState   => $state_failure,      # State to call on error
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

=item *

POE::Wheel::SocketFactory::getsockname()

Returns the value of getsockname() as called with the SocketFactory's
socket.

This is useful for finding out what the SocketFactory's internal
socket has bound to when it's been instructed to use BindAddress =>
INADDR_ANY and/or BindPort => INADDR_ANY.

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

Many (if not all) of the croak/carp/warn/die statements should fire
back $state_failure instead.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
