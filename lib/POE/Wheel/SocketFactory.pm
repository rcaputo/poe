# $Id$

package POE::Wheel::SocketFactory;

use strict;
use Carp;
use Symbol;

use POSIX qw(fcntl_h errno_h);
use Socket;
use POE qw(Wheel);

sub CRIMSON_SCOPE_HACK ($) { 0 }
sub DEBUG () { 0 }

sub MY_SOCKET_HANDLE   () {  0 }
sub MY_UNIQUE_ID       () {  1 }
sub MY_STATE_SUCCESS   () {  2 }
sub MY_STATE_FAILURE   () {  3 }
sub MY_SOCKET_DOMAIN   () {  4 }
sub MY_STATE_ACCEPT    () {  5 }
sub MY_STATE_CONNECT   () {  6 }
sub MY_MINE_SUCCESS    () {  7 }
sub MY_MINE_FAILURE    () {  8 }
sub MY_SOCKET_PROTOCOL () {  9 }
sub MY_SOCKET_TYPE     () { 10 }
sub MY_SOCKET_SELECTED () { 11 }

# Provide a dummy EINPROGRESS for systems that don't have one.  Give
# it a documented value.
BEGIN {
  # http://support.microsoft.com/support/kb/articles/Q150/5/37.asp
  # defines EINPROGRESS as 10035.  We provide it here because some
  # Win32 users report POSIX::EINPROGRESS is not vendor-supported.
  if ($^O eq 'MSWin32') {
    eval '*EINPROGRESS = sub { 10036 };';
    eval '*EWOULDBLOCK = sub { 10035 };';
    eval '*F_GETFL     = sub {     0 };';
    eval '*F_SETFL     = sub {     0 };';
  }
}

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
    DOM_INET, { tcp  => SVROP_LISTENS,
                udp  => SVROP_NOTHING,
              },
  );

my %default_socket_type =
  ( DOM_UNIX, { none => SOCK_STREAM },
    DOM_INET, { tcp  => SOCK_STREAM,
                udp  => SOCK_DGRAM,
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

  my $domain = $map_family_to_domain{ $self->[MY_SOCKET_DOMAIN] };
  $domain = '(undef)' unless defined $domain;
  my $success_state = \$self->[MY_STATE_SUCCESS];
  my $failure_state = \$self->[MY_STATE_FAILURE];
  my $unique_id     =  $self->[MY_UNIQUE_ID];

  $poe_kernel->state
    ( $self->[MY_STATE_ACCEPT] = $self . ' select accept',
      sub {
        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');

        # subroutine starts here
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

        my $new_socket = gensym;
        my $peer = accept($new_socket, $handle);

        if ($peer) {
          my ($peer_addr, $peer_port);
          if ( $domain eq DOM_UNIX ) {
            $peer_addr = $peer_port = undef;
          }
          elsif ( $domain eq DOM_INET ) {
            ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
          }
          else {
            die "sanity failure: socket domain == $domain";
          }
          $k->call( $me, $$success_state,
                    $new_socket, $peer_addr, $peer_port,
                    $unique_id
                  );
        }
        elsif ($! != EWOULDBLOCK) {
          $$failure_state &&
            $k->call( $me, $$failure_state,
                      'accept', ($!+0), $!, $unique_id
                    );
        }
      }
    );

  $self->[MY_SOCKET_SELECTED] = 'yes';
  $poe_kernel->select_read( $self->[MY_SOCKET_HANDLE],
                            $self->[MY_STATE_ACCEPT]
                          );
}

#------------------------------------------------------------------------------
# Define the select handler that will finalize an established
# connection.

sub _define_connect_state {
  my $self = shift;

  my $domain = $map_family_to_domain{ $self->[MY_SOCKET_DOMAIN] };
  $domain = '(undef)' unless defined $domain;
  my $success_state   = \$self->[MY_STATE_SUCCESS];
  my $failure_state   = \$self->[MY_STATE_FAILURE];
  my $unique_id       =  $self->[MY_UNIQUE_ID];
  my $socket_selected = \$self->[MY_SOCKET_SELECTED];

  $poe_kernel->state
    ( $self->[MY_STATE_CONNECT] = $self . ' -> select connect',
      sub {
        # This prevents SEGV in older versions of Perl.
        0 && CRIMSON_SCOPE_HACK('<');

        # Grab some values and stop watching the socket.
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];
        undef $$socket_selected;
        $k->select($handle);

        # Throw a failure if the connection failed.
        $! = unpack('i', getsockopt($handle, SOL_SOCKET, SO_ERROR));
        if ($!) {
          (defined $$failure_state) and
            $k->call( $me, $$failure_state,
                      'connect', ($!+0), $!, $unique_id
                    );
          return;
        }

        # Get the remote address, or throw an error if that fails.
        my $peer = getpeername($handle);
        if ($!) {
          (defined $$failure_state) and
            $k->call( $me, $$failure_state,
                      'getpeername', ($!+0), $!, $unique_id
                    );
          return;
        }

        # Parse the remote address according to the socket's domain.
        my ($peer_addr, $peer_port);

        # UNIX sockets have some trouble with peer addresses.
        if ($domain eq DOM_UNIX) {
          if (defined $peer) {
            eval {
              $peer_addr = unpack_sockaddr_un($peer);
            };
            undef $peer_addr if length $@;
          }
        }

        # INET socket stacks tend not to.
        elsif ($domain eq DOM_INET) {
          if (defined $peer) {
            eval {
              ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
            };
            if (length $@) {
              $peer_port = $peer_addr = undef;
            }
          }
        }

        # What are we doing here?
        else {
          die "sanity failure: socket domain == $domain";
        }

        # Tell the session it went okay.
        $k->call( $me, $$success_state,
                  $handle, $peer_addr, $peer_port, $unique_id
                );
      }
    );

  $self->[MY_SOCKET_SELECTED] = 'yes';
  $poe_kernel->select_write( $self->[MY_SOCKET_HANDLE],
                             $self->[MY_STATE_CONNECT]
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
            ( $self->[MY_STATE_SUCCESS] = $self . ' success',
              $event
            );
          $self->[MY_MINE_SUCCESS] = 'yes';
        }
        else {
          if (ref($event) ne '') {
            carp "Strange reference used as SuccessState event";
          }
          $self->[MY_STATE_SUCCESS] = $event;
          undef $self->[MY_MINE_SUCCESS];
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
            ( $self->[MY_STATE_FAILURE] = $self . ' failure',
              $event
            );
          $self->[MY_MINE_FAILURE] = 'yes';
        }
        else {
          if (ref($event) ne '') {
            carp "Strange reference used as FailureState event (ignored)"
          }
          $self->[MY_STATE_FAILURE] = $event;
          undef $self->[MY_MINE_FAILURE];
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

  $self->[MY_SOCKET_SELECTED] = 'yes';
  if (defined $self->[MY_STATE_ACCEPT]) {
    $poe_kernel->select_read($self->[MY_SOCKET_HANDLE],
                             $self->[MY_STATE_ACCEPT]
                            );
  }
  elsif (defined $self->[MY_STATE_CONNECT]) {
    $poe_kernel->select_write( $self->[MY_SOCKET_HANDLE],
                               $self->[MY_STATE_CONNECT]
                             );
  }
  else {
    die "POE developer error - no state defined";
  }
}

#------------------------------------------------------------------------------

sub getsockname {
  my $self = shift;
  return undef unless defined $self->[MY_SOCKET_HANDLE];
  return getsockname($self->[MY_SOCKET_HANDLE]);
}

sub ID {
  return $_[0]->[MY_UNIQUE_ID];
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
  croak 'SuccessState required' unless (defined $params{SuccessState});
  croak 'FailureState required' unless (defined $params{FailureState});
  my $state_success = $params{SuccessState};
  my $state_failure = $params{FailureState};

  # Create the SocketServer.  Cache a copy of the socket handle.
  my $socket_handle = gensym();
  my $self = bless
    ( [ $socket_handle,                   # MY_SOCKET_HANDLE
        &POE::Wheel::allocate_wheel_id(), # MY_UNIQUE_ID
        $params{SuccessState},            # MY_STATE_SUCCESS
        $params{FailureState},            # MY_STATE_FAILURE
        undef,                            # MY_SOCKET_DOMAIN
        undef,                            # MY_STATE_ACCEPT
        undef,                            # MY_STATE_CONNECT
        undef,                            # MY_MINE_SUCCESS
        undef,                            # MY_MINE_FAILURE
        undef,                            # MY_SOCKET_PROTOCOL
        undef,                            # MY_SOCKET_TYPE
        undef,                            # MY_SOCKET_SELECTED
      ],
      $type
    );

  # Default to Internet sockets.
  $self->[MY_SOCKET_DOMAIN] = ( (defined $params{SocketDomain})
                             ? $params{SocketDomain}
                             : AF_INET
                           );

  # Abstract the socket domain into something we don't have to keep
  # testing duplicates of.
  my $abstract_domain = $map_family_to_domain{$self->[MY_SOCKET_DOMAIN]};
  unless (defined $abstract_domain) {
    $poe_kernel->yield( $state_failure,
                        'domain', 0, '', $self->[MY_UNIQUE_ID]
                      );
    return $self;
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
      if defined $params{SocketProtocol};
    $self->[MY_SOCKET_PROTOCOL] = PF_UNSPEC;
    $protocol_name = 'none';
  }

  # Internet sockets use protocols.  Default the INET protocol to tcp,
  # and try to resolve it.
  elsif ($abstract_domain eq DOM_INET) {
    my $socket_protocol =
      (defined $params{SocketProtocol}) ? $params{SocketProtocol} : 'tcp';

    if ($socket_protocol !~ /^\d+$/) {
      unless ($socket_protocol = getprotobyname($socket_protocol)) {
        $poe_kernel->yield( $state_failure,
                            'getprotobyname', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }
    }

    # Get the protocol's name regardless of what was provided.  If the
    # protocol isn't supported, croak now instead of making the
    # programmer wonder why things fail later.
    $protocol_name = lc(getprotobynumber($socket_protocol));
    unless ($protocol_name) {
      $poe_kernel->yield( $state_failure,
                          'getprotobynumber', $!+0, $!, $self->[MY_UNIQUE_ID]
                        );
      return $self;
    }

    unless (defined $supported_protocol{$abstract_domain}->{$protocol_name}) {
      croak "SocketFactory does not support Internet $protocol_name sockets";
    }

    $self->[MY_SOCKET_PROTOCOL] = $socket_protocol;
  }
  else {
    die "Mail this error to the author of POE: Internal consistency error";
  }

  # If no SocketType, default it to something appropriate.
  if (defined $params{SocketType}) {
    $self->[MY_SOCKET_TYPE] = $params{SocketType};
  }
  else {
    unless (defined $default_socket_type{$abstract_domain}->{$protocol_name}) {
      croak "SocketFactory does not support $abstract_domain $protocol_name";
    }
    $self->[MY_SOCKET_TYPE] =
      $default_socket_type{$abstract_domain}->{$protocol_name};
  }

  # Create the socket.
  unless (socket( $socket_handle, $self->[MY_SOCKET_DOMAIN],
                  $self->[MY_SOCKET_TYPE], $self->[MY_SOCKET_PROTOCOL]
                )
  ) {
    $poe_kernel->yield( $state_failure,
                        'socket', $!+0, $!, $self->[MY_UNIQUE_ID]
                      );
    return $self;
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

    # 126 is FIONBIO (some docs say 0x7F << 16)
    ioctl( $socket_handle,
           0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
           $set_it
         )
      or do {
        $poe_kernel->yield( $state_failure,
                            'ioctl', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      };
  }

  # Do it the way everyone else does.
  else {
    my $flags = fcntl($socket_handle, F_GETFL, 0)
      or do {
        $poe_kernel->yield( $state_failure,
                            'fcntl', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      };
    $flags = fcntl($socket_handle, F_SETFL, $flags | O_NONBLOCK)
      or do {
        $poe_kernel->yield( $state_failure,
                            'fcntl', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      };
  }

  # Make the socket reusable, if requested.
  if ( (defined $params{Reuse})
       and ( (lc($params{Reuse}) eq 'yes')
             or ( ($params{Reuse} =~ /\d+/)
                  and $params{Reuse}
                )
           )
     )
  {
    setsockopt($socket_handle, SOL_SOCKET, SO_REUSEADDR, 1)
      or do {
        $poe_kernel->yield( $state_failure,
                            'setsockopt', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
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
    if ((defined $params{BindAddress}) or (defined $params{BindPort})) {

      # Set the bind address, or default to INADDR_ANY.
      $bind_address = ( (defined $params{BindAddress})
                        ? $params{BindAddress}
                        : INADDR_ANY
                      );

      # Resolve the bind address if it's not already packed.
      (length($bind_address) == 4)
        or ($bind_address = inet_aton($bind_address));
      unless (defined $bind_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $state_failure,
                            'inet_aton', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      # Set the bind port, or default to 0 (any) if none specified.
      # Resolve it to a number, if at all possible.
      my $bind_port = (defined $params{BindPort}) ? $params{BindPort} : 0;
      if ($bind_port =~ /[^0-9]/) {
        $bind_port = getservbyname($bind_port, $protocol_name);
        unless (defined $bind_port) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield( $state_failure,
                              'getservbyname', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        }
      }

      $bind_address = pack_sockaddr_in($bind_port, $bind_address);
      unless (defined $bind_address) {
        $poe_kernel->yield( $state_failure,
                            'pack_sockaddr_in', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }
    }
  }

  # Check SocketFactory /Bind.*/ parameters in a Unix context, and
  # translate them into parameters bind() understands.
  elsif ($abstract_domain eq DOM_UNIX) {
    carp 'BindPort ignored for Unix socket' if defined $params{BindPort};

    if (defined $params{BindAddress}) {
      # Is this necessary, or will bind() return EADDRINUSE?
      if (defined $params{RemotePort}) {
        $! = EADDRINUSE;
        $poe_kernel->yield( $state_failure,
                            'bind', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      $bind_address = &condition_unix_address($params{BindAddress});
      $bind_address = pack_sockaddr_un($bind_address);
      unless ($bind_address) {
        $poe_kernel->yield( $state_failure,
                            'pack_sockaddr_un', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
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
      $poe_kernel->yield( $state_failure,
                          'bind', $!+0, $!, $self->[MY_UNIQUE_ID]
                        );
      return $self;
    }

    DEBUG && warn "bind";
  }

  #---------#
  # Connect #
  #---------#

  my $connect_address;

  if (defined $params{RemoteAddress}) {

    # Check SocketFactory /Remote.*/ parameters in an Internet socket
    # context, and translate them into parameters that connect()
    # understands.
    if ($abstract_domain eq DOM_INET) {
                                        # connecting if RemoteAddress
      croak 'RemotePort required' unless (defined $params{RemotePort});
      carp 'ListenQueue ignored' if (defined $params{ListenQueue});

      my $remote_port = $params{RemotePort};
      if ($remote_port =~ /[^0-9]/) {
        unless ($remote_port = getservbyname($remote_port, $protocol_name)) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield( $state_failure,
                              'getservbyname', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        }
      }

      $connect_address = inet_aton($params{RemoteAddress});
      unless (defined $connect_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $state_failure,
                            'inet_aton', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      $connect_address = pack_sockaddr_in($remote_port, $connect_address);
      unless ($connect_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $state_failure,
                            'pack_sockaddr_in', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }
    }

    # Check SocketFactory /Remote.*/ parameters in a Unix socket
    # context, and translate them into parameters connect()
    # understands.
    elsif ($abstract_domain eq DOM_UNIX) {

      $connect_address = condition_unix_address($params{RemoteAddress});
      $connect_address = pack_sockaddr_un($connect_address);
      unless (defined $connect_address) {
        $poe_kernel->yield( $state_failure,
                            'pack_sockaddr_un', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
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
      if defined $params{RemotePort};
  }

  # Perform the actual connection, if a connection was requested.  If
  # the connection can be established, then return the SocketFactory
  # handle.
  if (defined $connect_address) {
    unless (connect($socket_handle, $connect_address)) {

      # XXX EINPROGRESS is not included in ActiveState's POSIX.pm, and
      # I don't know what AS's Perl uses instead.  What to do here?

      if ($! and ($! != EINPROGRESS) and ($! != EWOULDBLOCK)) {
        $poe_kernel->yield( $state_failure,
                            'connect', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }
    }

    DEBUG && warn "connect";

    $self->[MY_SOCKET_HANDLE] = $socket_handle;
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
        $poe_kernel->yield( $state_failure,
                            'listen', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      DEBUG && warn "listen";

      $self->[MY_SOCKET_HANDLE] = $socket_handle;
      $self->_define_accept_state();
      $self->event( SuccessState => $params{SuccessState},
                    FailureState => $params{FailureState},
                  );
      return $self;
    }
    else {
      carp "Ignoring ListenQueue parameter for non-listening socket"
        if defined $params{ListenQueue};
      if ($protocol_op eq SVROP_NOTHING) {
        # Do nothing.  Duh.  Fire off a success event immediately, and
        # return.
        $poe_kernel->yield( $state_success,
                            $socket_handle, undef, undef, $self->[MY_UNIQUE_ID]
                          );
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

  if (defined $self->[MY_SOCKET_SELECTED]) {
    undef $self->[MY_SOCKET_SELECTED];
    $poe_kernel->select($self->[MY_SOCKET_HANDLE]);
  }

  if (defined $self->[MY_STATE_ACCEPT]) {
    $poe_kernel->state($self->[MY_STATE_ACCEPT]);
    undef $self->[MY_STATE_ACCEPT];
  }

  if (defined $self->[MY_STATE_CONNECT]) {
    $poe_kernel->state($self->[MY_STATE_CONNECT]);
    undef $self->[MY_STATE_CONNECT];
  }

  if (defined $self->[MY_MINE_SUCCESS]) {
    $poe_kernel->state($self->[MY_STATE_SUCCESS]);
    undef $self->[MY_STATE_SUCCESS];
  }

  if (defined $self->[MY_MINE_FAILURE]) {
    $poe_kernel->state($self->[MY_STATE_FAILURE]);
    undef $self->[MY_STATE_FAILURE];
  }

  &POE::Wheel::free_wheel_id($self->[MY_UNIQUE_ID]);
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::SocketFactory - non-blocking socket creation and management

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

  $wheel->ID();

=head1 DESCRIPTION

SocketFactory creates sockets.  It can create connectionless sockets
like UDP, or connected sockets like UNIX domain streams and TCP
sockets.

The SocketFactory manages connecting and listening sockets on behalf
of the session that created it.  It will watch a connecting socket and
fire a SuccessState or FailureState event when something happens.  It
will watch a listening socket and fire a SuccessState or FailureState
event for every connection.

=head1 PUBLIC METHODS

=over 2

=item new LOTS_OF_THINGS

new() creates a new socket.  If necessary, it registers event handlers
to manage the socket.  new() has parameters for just about every
aspect of socket creation; thankfully they all aren't needed at once.

new() always returns a SocketFactory wheel reference, even if a socket
couldn't be created.

These parameters provide information for the SocketFactory's socket()
call.

=over 2

=item SocketDomain

SocketDomain supplies socket() with its DOMAIN parameter.  Supported
values are AF_UNIX, AF_INET, PF_UNIX and PF_INET.  If SocketDomain is
omitted, it defaults to AF_INET.

=item SocketType

SocketType supplies socket() with its TYPE parameter.  Supported
values are SOCK_STREAM and SOCK_DGRAM, although datagram sockets
haven't been tested at this time.  If SocketType is omitted, it
defaults to SOCK_STREAM.

=item SocketProtocol

SocketProtocol supplies socket() with its PROTOCOL parameter.
Protocols may be specified by number or by a name that can be found in
the system's protocol (or equivalent) database.  SocketProtocol is
ignored for UNIX domain sockets.  It defaults to 'tcp' if it's omitted
from an INET socket factory.

=back

These parameters provide information for the SocketFactory's bind()
call.

=over 2

=item BindAddress

BindAddress supplies the address where a socket will be bound to.  It
has different meanings and formats depending on the socket domain.

BindAddress may contain either a string or a packed Internet address
when it's specified for INET sockets.  The string form of BindAddress
should hold a dotted numeric address or resolvable host name.
BindAddress is optional for INET sockets, and SocketFactory will use
INADDR_ANY by default.

When used to bind a UNIX domain socket, BindAddress should contain a
path describing the socket's filename.  This is required for server
sockets and datagram client sockets.  BindAddress has no default value
for UNIX sockets.

=item BindPort

BindPort is only meaningful for INET domain sockets.  It contains a
port on the BindAddress interface where the socket will be bound.  It
defaults to 0 if omitted.

BindPort may be a port number or a name that can be looked up in the
system's services (or equivalent) database.

=back

These parameters are used for outbound sockets.

=over 2

=item RemoteAddress

RemoteAddress specifies the remote address to which a socket should
connect.  If present, the SocketFactory will create a connecting
socket.  Otherwise, it will make a listening socket, should the
protocol warrant it.

Like with the bind address, RemoteAddress may be a string containing a
dotted quad or a resolvable host name.  It may also be a packed
Internet address, or a UNIX socket path.  It will be packed, with or
without an accompanying RemotePort, as necessary for the socket
domain.

=item RemotePort

RemotePort is the port to which the socket should connect.  It is
required for connecting Internet sockets and ignored in all other
cases.

The remote port may be a number or a name in the /etc/services (or
equivalent) database.

=back

This parameter is used for listening sockets.

=over 2

=item ListenQueue

ListenQueue specifies the length of the socket's listen() queue.  It
defaults to SOMAXCONN if omitted.  SocketFactory will ensure that it
doesn't exceed SOMAXCONN.

=back

=item event EVENT_TYPE => EVENT_NAME, ...

event() is covered in the POE::Wheel manpage.

=item getsockname

getsockname() behaves like the built-in function of the same name.
Because the SocketFactory's underlying socket is hidden away, it's
hard to do this directly.

It's useful for finding which address and/or port the SocketFactory
has bound to when it's been instructed to use BindAddress =>
INADDR_ANY or BindPort => 0.

=item ID

The ID method returns a FollowTail wheel's unique ID.  This ID will be
included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item SuccessState

SuccessState defines the event that will be emitted when a socket has
been established successfully.  The SuccessState event is fired when
outbound sockets have connected or whenever listening sockets accept
new connections.

In all cases, C<ARG0> holds the new socket handle.  C<ARG3> holds the
wheel's unique ID.  The parameters between them differ according to
the socket's domain and whether it's listening or connecting.

For INET sockets, C<ARG1> and C<ARG2> hold the socket's remote address
and port, respectively.

For UNIX B<client> sockets, C<ARG1> holds the server address.  It may
be undefined on systems that have trouble retrieving a UNIX socket's
remote address.  C<ARG2> is always undefined for UNIX B<client>
sockets.

According to _Perl Cookbook_, the remote address returned by accept()
on UNIX sockets is undefined, so C<ARG1> and C<ARG2> are also
undefined in this case.

A sample SuccessState event handler:

  sub server_accept {
    my $accepted_handle = $_[ARG0];

    my $peer_host = inet_ntoa($_[ARG1]);
    print( "Wheel $_[ARG3] accepted a connection from ",
           "$peer_host port $peer_port\n"
         );

    # Do something with the new connection.
    &spawn_connection_session( $accepted_handle );
  }

=item FailureState

FailureState defines the event that will be emitted when a socket
error occurs.  EAGAIN does not count as an error since the
SocketFactory knows what to do with it.

The FailureState event comes with the standard error event parameters.

C<ARG0> contains the name of the operation that failed.  C<ARG1> and
C<ARG2> hold numeric and string values for C<$!>, respectively.
C<ARG3> contains the wheel's unique ID, which may be matched back to
the wheel itself via the $wheel->ID call.

A sample ErrorState event handler:

  sub error_state {
    my ($operation, $errnum, $errstr, $wheel_id) = @_[ARG0..ARG3];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
    delete $heap->{wheels}->{$wheel_id}; # shut down that wheel
  }

=back

=head1 SEE ALSO

POE::Wheel.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Many (if not all) of the croak/carp/warn/die statements should fire
back $state_failure instead.

SocketFactory is only tested with UNIX streams and INET sockets using
the UDP and TCP protocols.  Others may or may not work, but the latest
design is data driven and should be easy to extend.  Patches are
welcome, as are test cases for new families and protocols.  Even if
test cases fail, they'll make nice reference code to test additions to
the SocketFactory class.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
