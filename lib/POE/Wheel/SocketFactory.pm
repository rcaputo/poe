# $Id$

package POE::Wheel::SocketFactory;
use POE::Preprocessor ( isa => "POE::Macro::UseBytes" );

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use Carp;
use Symbol;

use POSIX qw(fcntl_h);
use Errno qw(EWOULDBLOCK EADDRNOTAVAIL EINPROGRESS EADDRINUSE);
use Socket;
use POE qw(Wheel);

sub CRIMSON_SCOPE_HACK ($) { 0 }
sub DEBUG () { 0 }

sub MY_SOCKET_HANDLE   () {  0 }
sub MY_UNIQUE_ID       () {  1 }
sub MY_EVENT_SUCCESS   () {  2 }
sub MY_EVENT_FAILURE   () {  3 }
sub MY_SOCKET_DOMAIN   () {  4 }
sub MY_STATE_ACCEPT    () {  5 }
sub MY_STATE_CONNECT   () {  6 }
sub MY_MINE_SUCCESS    () {  7 }
sub MY_MINE_FAILURE    () {  8 }
sub MY_SOCKET_PROTOCOL () {  9 }
sub MY_SOCKET_TYPE     () { 10 }
sub MY_STATE_ERROR     () { 11 }
sub MY_SOCKET_SELECTED () { 12 }

# Fletch has subclassed SSLSocketFactory from SocketFactory.  He's
# added new members after MY_SOCKET_SELECTED.  Be sure, if you extend
# this, to extend add stuff BEFORE MY_SOCKET_SELECTED or let Fletch
# know you've broken his module.

# Provide dummy constants for systems that don't have them.
BEGIN {
  if ($^O eq 'MSWin32') {

    # Constants are evaluated first so they exist when the code uses
    # them.
    eval( '*F_GETFL       = sub {     0 };' .
          '*F_SETFL       = sub {     0 };' .

          # Garrett Goebel's patch to support non-blocking connect()
          # or MSWin32 follows.  His notes on the matter:
          #
          # As my patch appears to turn on the overlapped attributes
          # for all successive sockets... it might not be the optimal
          # solution. But it works for me ;)
          #
          # A better Win32 approach would probably be to:
          # o  create a dummy socket
          # o  cache the value of SO_OPENTYPE
          # o  set the overlapped io attribute
          # o  close dummy socket
          #
          # o  create our sock
          #
          # o  create a dummy socket
          # o  restore previous value of SO_OPENTYPE
          # o  close dummy socket
          #
          # This way we'd only be turning on the overlap attribute for
          # the socket we created... and not all subsequent sockets.

          '*SO_OPENTYPE = sub () { 0x7008 };' .
          '*SO_SYNCHRONOUS_ALERT    = sub () { 0x10 };' .
          '*SO_SYNCHRONOUS_NONALERT = sub () { 0x20 };'
        );
    die if $@;

    # Turn on socket overlapped IO attribute per MSKB: Q181611.  This
    # concludes Garrett's patch.

    eval( 'socket(POE, AF_INET, SOCK_STREAM, getprotobyname("tcp"))' .
          'or die "socket failed: $!";' .
          'my $opt = unpack("I", getsockopt(POE, SOL_SOCKET, SO_OPENTYPE));' .
          '$opt &= ~(SO_SYNCHRONOUS_ALERT|SO_SYNCHRONOUS_NONALERT);' .
          'setsockopt(POE, SOL_SOCKET, SO_OPENTYPE, $opt);' .
          'close POE;'

          # End of Garrett's patch.
        );
    die if $@;
  }

  unless (exists $INC{"Socket6.pm"}) {
    eval "*Socket6::AF_INET6 = sub () { ~0 }";
    eval "*Socket6::PF_INET6 = sub () { ~0 }";
  }
}

#------------------------------------------------------------------------------
# These tables customize the socketfactory.  Many protocols share the
# same operations, it seems, and this is a way to add new ones with a
# minimum of additional code.

sub DOM_UNIX  () { 'unix'  }  # UNIX domain socket
sub DOM_INET  () { 'inet'  }  # INET domain socket
sub DOM_INET6 () { 'inet6' }  # INET v6 domain socket

# AF_XYZ and PF_XYZ may be different.
my %map_family_to_domain =
  ( AF_UNIX,  DOM_UNIX,  PF_UNIX,  DOM_UNIX,
    AF_INET,  DOM_INET,  PF_INET,  DOM_INET,
    &Socket6::AF_INET6, DOM_INET6,
    &Socket6::PF_INET6, DOM_INET6,
  );

sub SVROP_LISTENS () { 'listens' }  # connect/listen sockets
sub SVROP_NOTHING () { 'nothing' }  # connectionless sockets

# Map family/protocol pairs to connection or connectionless
# operations.
my %supported_protocol =
  ( DOM_UNIX,  { none => SVROP_LISTENS },
    DOM_INET,  { tcp  => SVROP_LISTENS,
                 udp  => SVROP_NOTHING,
               },
    DOM_INET6, { tcp  => SVROP_LISTENS,
                 udp  => SVROP_NOTHING,
               },
  );

# Sane default socket types for each supported protocol.  -><- Maybe
# this structure can be combined with %supported_protocol?
my %default_socket_type =
  ( DOM_UNIX,  { none => SOCK_STREAM },
    DOM_INET,  { tcp  => SOCK_STREAM,
                 udp  => SOCK_DGRAM,
               },
    DOM_INET6, { tcp  => SOCK_STREAM,
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

  # We do these stupid closure tricks to avoid putting $self in it
  # directly.  If you include $self in one of the state() closures,
  # the component will fail to shut down properly: there will be a
  # circular definition in the closure holding $self alive.

  my $domain = $map_family_to_domain{ $self->[MY_SOCKET_DOMAIN] };
  $domain = '(undef)' unless defined $domain;
  my $event_success = \$self->[MY_EVENT_SUCCESS];
  my $event_failure = \$self->[MY_EVENT_FAILURE];
  my $unique_id     =  $self->[MY_UNIQUE_ID];

  $poe_kernel->state
    ( $self->[MY_STATE_ACCEPT] = ref($self) . "($unique_id) -> select accept",
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
          elsif ( $domain eq DOM_INET6 ) {
            $peer = getpeername($new_socket);
            ($peer_port, $peer_addr) = Socket6::unpack_sockaddr_in6($peer);
          }
          else {
            die "sanity failure: socket domain == $domain";
          }
          $k->call( $me, $$event_success,
                    $new_socket, $peer_addr, $peer_port,
                    $unique_id
                  );
        }
        elsif ($! != EWOULDBLOCK) {
          $$event_failure &&
            $k->call( $me, $$event_failure,
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

  # We do these stupid closure tricks to avoid putting $self in it
  # directly.  If you include $self in one of the state() closures,
  # the component will fail to shut down properly: there will be a
  # circular definition in the closure holding $self alive.

  my $domain = $map_family_to_domain{ $self->[MY_SOCKET_DOMAIN] };
  $domain = '(undef)' unless defined $domain;
  my $event_success   = \$self->[MY_EVENT_SUCCESS];
  my $event_failure   = \$self->[MY_EVENT_FAILURE];
  my $unique_id       =  $self->[MY_UNIQUE_ID];
  my $socket_selected = \$self->[MY_SOCKET_SELECTED];

  my $socket_handle   = \$self->[MY_SOCKET_HANDLE];
  my $state_accept    = \$self->[MY_STATE_ACCEPT];
  my $state_connect   = \$self->[MY_STATE_CONNECT];
  my $mine_success    = \$self->[MY_MINE_SUCCESS];
  my $mine_failure    = \$self->[MY_MINE_FAILURE];

  $poe_kernel->state
    ( $self->[MY_STATE_CONNECT] = ( ref($self) .
                                    "($unique_id) -> select connect"
                                  ),
      sub {
        # This prevents SEGV in older versions of Perl.
        0 && CRIMSON_SCOPE_HACK('<');

        # Grab some values and stop watching the socket.
        my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

	_shutdown(
	  $socket_selected, $socket_handle,
	  $state_accept, $state_connect,
	  $mine_success, $event_success,
	  $mine_failure, $event_failure,
	);

        # Throw a failure if the connection failed.
        $! = unpack('i', getsockopt($handle, SOL_SOCKET, SO_ERROR));
        if ($!) {
          (defined $$event_failure) and
            $k->call( $me, $$event_failure,
                      'connect', ($!+0), $!, $unique_id
                    );
          return;
        }

        # Get the remote address, or throw an error if that fails.
        my $peer = getpeername($handle);
        if ($!) {
          (defined $$event_failure) and
            $k->call( $me, $$event_failure,
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

        # INET6 socket stacks tend not to.
        elsif ($domain eq DOM_INET6) {
          if (defined $peer) {
            eval {
              ($peer_port, $peer_addr) = Socket6::unpack_sockaddr_in6($peer);
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

        # Tell the session it went okay.  Also let go of the socket.
        $k->call( $me, $$event_success,
                  $handle, $peer_addr, $peer_port, $unique_id
                );
      }
    );

  # Cygwin expects an error state registered to expedite.  This code
  # is nearly identical the stuff above.
  if ($^O eq "cygwin") {
    $poe_kernel->state
      ( $self->[MY_STATE_ERROR] = ( ref($self) .
                                    "($unique_id) -> connect error"
                                  ),
        sub {
          # This prevents SEGV in older versions of Perl.
          0 && CRIMSON_SCOPE_HACK('<');

          # Grab some values and stop watching the socket.
          my ($k, $me, $handle) = @_[KERNEL, SESSION, ARG0];

	  _shutdown(
	    $socket_selected, $socket_handle,
	    $state_accept, $state_connect,
	    $mine_success, $event_success,
	    $mine_failure, $event_failure,
	  );

          # Throw a failure if the connection failed.
          $! = unpack('i', getsockopt($handle, SOL_SOCKET, SO_ERROR));
          if ($!) {
            (defined $$event_failure) and
              $k->call( $me, $$event_failure,
                        'connect', ($!+0), $!, $unique_id
                      );
            return;
          }
        }
      );
    $poe_kernel->select_expedite( $self->[MY_SOCKET_HANDLE],
                                  $self->[MY_STATE_ERROR]
                                );
  }

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

    if ($name eq 'SuccessEvent') {
      if (defined $event) {
        if (ref($event)) {
          carp "reference for SuccessEvent will be treated as an event name"
        }
        $self->[MY_EVENT_SUCCESS] = $event;
        undef $self->[MY_MINE_SUCCESS];
      }
      else {
        carp "SuccessEvent requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'FailureEvent') {
      if (defined $event) {
        if (ref($event)) {
          carp "reference for FailureEvent will be treated as an event name";
        }
        $self->[MY_EVENT_FAILURE] = $event;
        undef $self->[MY_MINE_FAILURE];
      }
      else {
        carp "FailureEvent requires an event name.  ignoring undef";
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
    if ($^O eq "cygwin") {
      $poe_kernel->select_expedite( $self->[MY_SOCKET_HANDLE],
                                    $self->[MY_STATE_ERROR]
                                  );
    }
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

  # Don't take responsibility for a bad parameter count.
  croak "$type requires an even number of parameters" if @_ & 1;

  my %params = @_;

  # The calling convention experienced a hard deprecation.
  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  # Ensure some of the basic things are present.
  croak "$type requires a working Kernel" unless (defined $poe_kernel);
  croak 'SuccessEvent required' unless (defined $params{SuccessEvent});
  croak 'FailureEvent required' unless (defined $params{FailureEvent});
  my $event_success = $params{SuccessEvent};
  my $event_failure = $params{FailureEvent};

  # Create the SocketServer.  Cache a copy of the socket handle.
  my $socket_handle = gensym();
  my $self = bless
    ( [ $socket_handle,                   # MY_SOCKET_HANDLE
        &POE::Wheel::allocate_wheel_id(), # MY_UNIQUE_ID
        $event_success,                   # MY_EVENT_SUCCESS
        $event_failure,                   # MY_EVENT_FAILURE
        undef,                            # MY_SOCKET_DOMAIN
        undef,                            # MY_STATE_ACCEPT
        undef,                            # MY_STATE_CONNECT
        undef,                            # MY_MINE_SUCCESS
        undef,                            # MY_MINE_FAILURE
        undef,                            # MY_SOCKET_PROTOCOL
        undef,                            # MY_SOCKET_TYPE
        undef,                            # MY_STATE_ERROR
        undef,                            # MY_SOCKET_SELECTED
      ],
      $type
    );

  # Default to Internet sockets.
  my $domain = delete $params{SocketDomain};
  $domain = AF_INET unless defined $domain;
  $self->[MY_SOCKET_DOMAIN] = $domain;

  # Abstract the socket domain into something we don't have to keep
  # testing duplicates of.
  my $abstract_domain = $map_family_to_domain{$self->[MY_SOCKET_DOMAIN]};
  unless (defined $abstract_domain) {
    $poe_kernel->yield( $event_failure,
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
  elsif ( $abstract_domain eq DOM_INET or
          $abstract_domain eq DOM_INET6
        ) {
    my $socket_protocol =
      (defined $params{SocketProtocol}) ? $params{SocketProtocol} : 'tcp';

    if ($socket_protocol !~ /^\d+$/) {
      unless ($socket_protocol = getprotobyname($socket_protocol)) {
        $poe_kernel->yield( $event_failure,
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
      $poe_kernel->yield( $event_failure,
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
    $poe_kernel->yield( $event_failure,
                        'socket', $!+0, $!, $self->[MY_UNIQUE_ID]
                      );
    return $self;
  }

  DEBUG && warn "socket";

  #------------------#
  # Configure Socket #
  #------------------#

  # Make the socket binary.  It's wrapped in eval{} because tied
  # filehandle classes may actually die in their binmode methods.
  eval { binmode($socket_handle) };

  # Don't block on socket operations, because the socket will be
  # driven by a select loop.

  # RCC 2002-12-19: Replace the complex blocking checks and methods
  # with IO::Handle's blocking(0) method.  This is theoretically more
  # portable and less maintenance than rolling our own.  If things
  # work out, we'll remove the commented out code.

  # RCC 2003-01-20: Unfortunately, blocking() isn't available in perl
  # 5.005_03, and people still use that.  We'll use blocking() for
  # Perl 5.8.0 and beyond, since that's the first version of
  # ActivePerl that has a problem.

  if ($] >= 5.008) {
    $socket_handle->blocking(0);
  }
  else {
    # Do it the Win32 way.  XXX This is incomplete.
    if ($^O eq 'MSWin32') {
      my $set_it = "1";

      # 126 is FIONBIO (some docs say 0x7F << 16)
      ioctl( $socket_handle,
             0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
             $set_it
           )
        or do {
          $poe_kernel->yield( $event_failure,
                              'ioctl', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        };
    }

    # Do it the way everyone else does.
    else {
      my $flags = fcntl($socket_handle, F_GETFL, 0)
        or do {
          $poe_kernel->yield( $event_failure,
                              'fcntl', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        };
      $flags = fcntl($socket_handle, F_SETFL, $flags | O_NONBLOCK)
        or do {
          $poe_kernel->yield( $event_failure,
                              'fcntl', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        };
    }
  }

  # Make the socket reusable, if requested.
  if ( (defined $params{Reuse})
       and ( (lc($params{Reuse}) eq 'yes')
             or (lc($params{Reuse}) eq 'on')
             or ( ($params{Reuse} =~ /\d+/)
                  and $params{Reuse}
                )
           )
     )
  {
    setsockopt($socket_handle, SOL_SOCKET, SO_REUSEADDR, 1)
      or do {
        $poe_kernel->yield( $event_failure,
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

      {% use_bytes %}

      # Resolve the bind address if it's not already packed.
      unless (length($bind_address) == 4) {
        $bind_address = inet_aton($bind_address);
      }

      unless (defined $bind_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $event_failure,
                            "inet_aton", $!+0, $!, $self->[MY_UNIQUE_ID]
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
          $poe_kernel->yield( $event_failure,
                              'getservbyname', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        }
      }

      $bind_address = pack_sockaddr_in($bind_port, $bind_address);
      unless (defined $bind_address) {
        $poe_kernel->yield( $event_failure,
                            "pack_sockaddr_in", $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }
    }
  }

  # Check SocketFactory /Bind.*/ parameters in an Internet socket
  # context, and translate them into parameters that bind()
  # understands.
  elsif ($abstract_domain eq DOM_INET6) {

    # Don't bind if the creator doesn't specify a related parameter.
    if ((defined $params{BindAddress}) or (defined $params{BindPort})) {

      # Set the bind address, or default to INADDR_ANY.
      $bind_address = (
        (defined $params{BindAddress})
        ? $params{BindAddress}
        : Socket6::in6addr_any()
      );

      # Set the bind port, or default to 0 (any) if none specified.
      # Resolve it to a number, if at all possible.
      my $bind_port = (defined $params{BindPort}) ? $params{BindPort} : 0;
      if ($bind_port =~ /[^0-9]/) {
        $bind_port = getservbyname($bind_port, $protocol_name);
        unless (defined $bind_port) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield( $event_failure,
                              'getservbyname', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        }
      }

      {% use_bytes %}

      # Resolve the bind address.
      my @info = Socket6::getaddrinfo(
        $bind_address, $bind_port,
        $self->[MY_SOCKET_DOMAIN], $self->[MY_SOCKET_TYPE],
      );

# Deprecated Socket6 interfaces.  Solaris, for one, does not use them.
# TODO - Remove this if nothing needs it.
#      $bind_address =
#        Socket6::gethostbyname2($bind_address, $self->[MY_SOCKET_DOMAIN]);

      if (@info < 5) {  # unless defined $bind_address
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $event_failure,
                            "getaddrinfo", $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      $bind_address = $info[3];

# Deprecated Socket6 interfaces.  Solaris, for one, does not use them.
# TODO - Remove this if nothing needs it.
#      $bind_address = Socket6::pack_sockaddr_in6($bind_port, $bind_address);
#      warn unpack "H*", $bind_address;
#      unless (defined $bind_address) {
#        $poe_kernel->yield( $event_failure,
#                            "pack_sockaddr_in6", $!+0, $!,
#                            $self->[MY_UNIQUE_ID]
#                          );
#        return $self;
#      }
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
        $poe_kernel->yield( $event_failure,
                            'bind', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      $bind_address = &condition_unix_address($params{BindAddress});
      $bind_address = pack_sockaddr_un($bind_address);
      unless ($bind_address) {
        $poe_kernel->yield( $event_failure,
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
      $poe_kernel->yield( $event_failure,
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
    if ($abstract_domain eq DOM_INET or
        $abstract_domain eq DOM_INET6
       ) {
      # connecting if RemoteAddress
      croak 'RemotePort required' unless (defined $params{RemotePort});
      carp 'ListenQueue ignored' if (defined $params{ListenQueue});

      my $remote_port = $params{RemotePort};
      if ($remote_port =~ /[^0-9]/) {
        unless ($remote_port = getservbyname($remote_port, $protocol_name)) {
          $! = EADDRNOTAVAIL;
          $poe_kernel->yield( $event_failure,
                              'getservbyname', $!+0, $!, $self->[MY_UNIQUE_ID]
                            );
          return $self;
        }
      }

      my $error_tag;
      if ($abstract_domain eq DOM_INET) {
        $connect_address = inet_aton($params{RemoteAddress});
        $error_tag = "inet_aton";
      }
      elsif ($abstract_domain eq DOM_INET6) {
        my @info = Socket6::getaddrinfo(
          $params{RemoteAddress}, $remote_port,
          $self->[MY_SOCKET_DOMAIN], $self->[MY_SOCKET_TYPE],
        );

        if (@info < 5) {
          $connect_address = undef;
        }
        else {
          $connect_address = $info[3];
        }

        $error_tag = "getaddrinfo";

# Deprecated Socket6 interfaces.  Solaris, for one, does not use them.
# TODO - Remove this if nothing needs it.
#        $connect_address =
#          Socket6::gethostbyname2( $params{RemoteAddress},
#                                   $self->[MY_SOCKET_DOMAIN]
#                                 );
#        $error_tag = "gethostbyname2";
      }
      else {
        die "unknown domain $abstract_domain";
      }

      # TODO - If the gethostbyname2() code is removed, then we can
      # combine the previous code with the following code, and perhaps
      # remove one of these redundant $connect_address checks.  The
      # 0.29 release should tell us pretty quickly whether it's
      # needed.  If we reach 0.30 without incident, it's probably safe
      # to remove the old gethostbyname2() code and clean this up.
      unless (defined $connect_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $event_failure,
                            $error_tag, $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      if ($abstract_domain eq DOM_INET) {
        $connect_address = pack_sockaddr_in($remote_port, $connect_address);
        $error_tag = "pack_sockaddr_in";
      }
      elsif ($abstract_domain eq DOM_INET6) {
# Deprecated Socket6 interfaces.  Solaris, for one, does not use them.
# TODO - Remove this if nothing needs it.
#        $connect_address =
#          Socket6::pack_sockaddr_in6($remote_port, $connect_address);
        $error_tag = "pack_sockaddr_in6";
      }
      else {
        die "unknown domain $abstract_domain";
      }

      unless ($connect_address) {
        $! = EADDRNOTAVAIL;
        $poe_kernel->yield( $event_failure,
                            $error_tag, $!+0, $!, $self->[MY_UNIQUE_ID]
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
        $poe_kernel->yield( $event_failure,
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
      if ($! and ($! != EINPROGRESS) and ($! != EWOULDBLOCK)) {
        $poe_kernel->yield( $event_failure,
                            'connect', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }
    }

    DEBUG && warn "connect";

    $self->[MY_SOCKET_HANDLE] = $socket_handle;
    $self->_define_connect_state();
    $self->event( SuccessEvent => $params{SuccessEvent},
                  FailureEvent => $params{FailureEvent},
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
      # <rmah> In SocketFactory, you limit the ListenQueue parameter
      #        to SOMAXCON (or is it SOCONNMAX?)...why?
      # <rmah> ah, here's czth, he'll have more to say on this issue
      # <czth> not really.  just that SOMAXCONN can lie, notably on
      #        Solaris and reportedly on BSDs too
      # 
      # ($listen_queue > SOMAXCONN) && ($listen_queue = SOMAXCONN);
      unless (listen($socket_handle, $listen_queue)) {
        $poe_kernel->yield( $event_failure,
                            'listen', $!+0, $!, $self->[MY_UNIQUE_ID]
                          );
        return $self;
      }

      DEBUG && warn "listen";

      $self->[MY_SOCKET_HANDLE] = $socket_handle;
      $self->_define_accept_state();
      $self->event( SuccessEvent => $params{SuccessEvent},
                    FailureEvent => $params{FailureEvent},
                  );
      return $self;
    }
    else {
      carp "Ignoring ListenQueue parameter for non-listening socket"
        if defined $params{ListenQueue};
      if ($protocol_op eq SVROP_NOTHING) {
        # Do nothing.  Duh.  Fire off a success event immediately, and
        # return.
        $poe_kernel->yield( $event_success,
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

# Pause and resume accept.
sub pause_accept {
  my $self = shift;
  if ( defined $self->[MY_SOCKET_HANDLE] and
       defined $self->[MY_STATE_ACCEPT] and
       defined $self->[MY_SOCKET_SELECTED]
     ) {
    $poe_kernel->select_pause_read($self->[MY_SOCKET_HANDLE]);
  }
}

sub resume_accept {
  my $self = shift;
  if ( defined $self->[MY_SOCKET_HANDLE] and
       defined $self->[MY_STATE_ACCEPT] and
       defined $self->[MY_SOCKET_SELECTED]
     ) {
    $poe_kernel->select_resume_read($self->[MY_SOCKET_HANDLE]);
  }
}

#------------------------------------------------------------------------------
# DESTROY and _shutdown pass things by reference because _shutdown is
# called from the state() closures above.  As a result, we can't
# mention $self explicitly, or the wheel won't shut itself down
# properly.  Rather, it will form a circular reference on $self.

sub DESTROY {
  my $self = shift;
  _shutdown(
    \$self->[MY_SOCKET_SELECTED],
    \$self->[MY_SOCKET_HANDLE],
    \$self->[MY_STATE_ACCEPT],
    \$self->[MY_STATE_CONNECT],
    \$self->[MY_MINE_SUCCESS],
    \$self->[MY_EVENT_SUCCESS],
    \$self->[MY_MINE_FAILURE],
    \$self->[MY_EVENT_FAILURE],
  );
  &POE::Wheel::free_wheel_id($self->[MY_UNIQUE_ID]);
}

sub _shutdown {
  my (
    $socket_selected, $socket_handle,
    $state_accept, $state_connect,
    $mine_success, $event_success,
    $mine_failure, $event_failure,
  ) = @_;

  if (defined $$socket_selected) {
    $poe_kernel->select($$socket_handle);
    $$socket_selected = undef;
  }

  if (defined $$state_accept) {
    $poe_kernel->state($$state_accept);
    $$state_accept = undef;
  }

  if (defined $$state_connect) {
    $poe_kernel->state($$state_connect);
    $$state_connect = undef;
  }

  if (defined $$mine_success) {
    $poe_kernel->state($$event_success);
    $$mine_success = $$event_success = undef;
  }

  if (defined $$mine_failure) {
    $poe_kernel->state($$event_failure);
    $$mine_failure = $$event_failure = undef;
  }
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::SocketFactory - non-blocking socket creation and management

=head1 SYNOPSIS

  use Socket; # For the constants

  # Listening Unix domain socket.
  $wheel = POE::Wheel::SocketFactory->new(
    SocketDomain => AF_UNIX,               # Sets the socket() domain
    BindAddress  => $unix_socket_address,  # Sets the bind() address
    SuccessEvent => $event_success,        # Event to emit upon accept()
    FailureEvent => $event_failure,        # Event to emit upon error
    # Optional parameters (and default values):
    SocketType   => SOCK_STREAM,           # Sets the socket() type
  );

  # Connecting Unix domain socket.
  $wheel = POE::Wheel::SocketFactory->new(
    SocketDomain  => AF_UNIX,              # Sets the socket() domain
    RemoteAddress => $unix_server_address, # Sets the connect() address
    SuccessEvent  => $event_success,       # Event to emit on connection
    FailureEvent  => $event_failure,       # Event to emit on error
    # Optional parameters (and default values):
    SocketType    => SOCK_STREAM,          # Sets the socket() type
    # Optional parameters (that have no defaults):
    BindAddress   => $unix_client_address, # Sets the bind() address
  );

  # Listening Internet domain socket.
  $wheel = POE::Wheel::SocketFactory->new(
    BindAddress    => $inet_address,       # Sets the bind() address
    BindPort       => $inet_port,          # Sets the bind() port
    SuccessEvent   => $event_success,      # Event to emit upon accept()
    FailureEvent   => $event_failure,      # Event to emit upon error
    # Optional parameters (and default values):
    SocketDomain   => AF_INET,             # Sets the socket() domain
    SocketType     => SOCK_STREAM,         # Sets the socket() type
    SocketProtocol => 'tcp',               # Sets the socket() protocol
    ListenQueue    => SOMAXCONN,           # The listen() queue length
    Reuse          => 'on',                # Lets the port be reused
  );

  # Connecting Internet domain socket.
  $wheel = POE::Wheel::SocketFactory->new(
    RemoteAddress  => $inet_address,       # Sets the connect() address
    RemotePort     => $inet_port,          # Sets the connect() port
    SuccessEvent   => $event_success,      # Event to emit on connection
    FailureEvent   => $event_failure,      # Event to emit on error
    # Optional parameters (and default values):
    SocketDomain   => AF_INET,             # Sets the socket() domain
    SocketType     => SOCK_STREAM,         # Sets the socket() type
    SocketProtocol => 'tcp',               # Sets the socket() protocol
    Reuse          => 'yes',               # Lets the port be reused
  );

  $wheel->event( ... );

  $wheel->ID();

  $wheel->pause_accept();
  $wheel->resume_accept();

=head1 DESCRIPTION

SocketFactory creates sockets.  It can create connectionless sockets
like UDP, or connected sockets like UNIX domain streams and TCP
sockets.

The SocketFactory manages connecting and listening sockets on behalf
of the session that created it.  It will watch a connecting socket and
fire a SuccessEvent or FailureEvent event when something happens.  It
will watch a listening socket and fire a SuccessEvent or FailureEvent
for every connection.

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
values are AF_UNIX, AF_INET, AF_INET6, PF_UNIX, PF_INET, and PF_INET6.
If SocketDomain is omitted, it defaults to AF_INET.

Note: AF_INET6 and PF_INET6 are supplied by the Socket6 module, which
is available on the CPAN.  You must have Socket6 loaded before
SocketFactory can create IPv6 sockets.

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

The ID method returns a SocketFactory wheel's unique ID.  This ID will
be included in every event the wheel generates, and it can be used to
match events with the wheels which generated them.

=item pause_accept

=item resume_accept

Listening SocketFactory instances will accept connections for as long
as they exist.  This may not be desirable in pre-forking servers where
the main process must not handle connections.

pause_accept() temporarily stops a SocketFactory from accepting new
connections.  It continues to listen, however.  resume_accept() ends a
temporary pause, allowing a SocketFactory to accept new connections.

In a pre-forking server, the main process would pause_accept()
immediately after the SocketFactory was created.  As forked child
processes start, they call resume_accept() to begin accepting
connections.

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item SuccessEvent

SuccessEvent defines the event that will be emitted when a socket has
been established successfully.  The SuccessEvent event is fired when
outbound sockets have connected or whenever listening sockets accept
new connections.

SuccessEvent must be the name of a state within the current session.

In all cases, C<ARG0> holds the new socket handle.  C<ARG3> holds the
wheel's unique ID.  The parameters between them differ according to
the socket's domain and whether it's listening or connecting.

For INET sockets, C<ARG1> and C<ARG2> hold the socket's remote address
and port, respectively.  The address is packed; use inet_ntoa() (See
L<Socket>) if a human-readable version is necessary.

For UNIX B<client> sockets, C<ARG1> holds the server address.  It may
be undefined on systems that have trouble retrieving a UNIX socket's
remote address.  C<ARG2> is always undefined for UNIX B<client>
sockets.

According to _Perl Cookbook_, the remote address returned by accept()
on UNIX sockets is undefined, so C<ARG1> and C<ARG2> are also
undefined in this case.

A sample SuccessEvent handler:

  sub server_accept {
    my $accepted_handle = $_[ARG0];

    my $peer_host = inet_ntoa($_[ARG1]);
    print( "Wheel $_[ARG3] accepted a connection from ",
           "$peer_host port $peer_port\n"
         );

    # Do something with the new connection.
    &spawn_connection_session( $accepted_handle );
  }

=item FailureEvent

FailureEvent defines the event that will be emitted when a socket
error occurs.  EAGAIN does not count as an error since the
SocketFactory knows what to do with it.

FailureEvent must be the name of a state within the current session.

The FailureEvent event comes with the standard error event parameters.

C<ARG0> contains the name of the operation that failed.  C<ARG1> and
C<ARG2> hold numeric and string values for C<$!>, respectively.
C<ARG3> contains the wheel's unique ID, which may be matched back to
the wheel itself via the $wheel->ID call.

A sample ErrorEvent handler:

  sub error_state {
    my ($operation, $errnum, $errstr, $wheel_id) = @_[ARG0..ARG3];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
    delete $heap->{wheels}->{$wheel_id}; # shut down that wheel
  }

=back

=head1 SEE ALSO

POE::Wheel, Socket6.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Many (if not all) of the croak/carp/warn/die statements should fire
back FailureEvent instead.

SocketFactory is only tested with UNIX streams and INET sockets using
the UDP and TCP protocols.  Others may or may not work, but the latest
design is data driven and should be easy to extend.  Patches are
welcome, as are test cases for new families and protocols.  Even if
test cases fail, they'll make nice reference code to test additions to
the SocketFactory class.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
