# $Id$

package POE::Component::Client::TCP;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use Carp qw(carp croak);
use Errno qw(ETIMEDOUT ECONNRESET);

# Explicit use to import the parameter constants;
use POE::Session;
use POE::Driver::SysRW;
use POE::Filter::Line;
use POE::Wheel::ReadWrite;
use POE::Wheel::SocketFactory;

# Create the client.  This is just a handy way to encapsulate
# POE::Session->create().  Because the states are so small, it uses
# real inline coderefs.

sub new {
  my $type = shift;

  # Helper so we don't have to type it all day.  $mi is a name I call
  # myself.
  my $mi = $type . '->new()';

  # If they give us lemons, tell them to make their own damn
  # lemonade.
  croak "$mi requires an even number of parameters" if (@_ & 1);
  my %param = @_;

  # Validate what we're given.
  croak "$mi needs a RemoteAddress parameter"
    unless exists $param{RemoteAddress};
  croak "$mi needs a RemotePort parameter"
    unless exists $param{RemotePort};

  # Extract parameters.
  my $alias           = delete $param{Alias};
  my $address         = delete $param{RemoteAddress};
  my $port            = delete $param{RemotePort};
  my $domain          = delete $param{Domain};
  my $bind_address    = delete $param{BindAddress};
  my $bind_port       = delete $param{BindPort};
  my $ctimeout        = delete $param{ConnectTimeout};
  my $args            = delete $param{Args};
  my $session_type    = delete $param{SessionType};
  my $session_params  = delete $param{SessionParams};

  $args = [] unless defined $args;
  croak "Args must be an array reference" unless ref($args) eq "ARRAY";

  foreach (
    qw( Connected ConnectError Disconnected ServerInput
      ServerError ServerFlushed Started
      ServerHigh ServerLow
    )
  ) {
    croak "$_ must be a coderef" if(
      defined($param{$_}) and ref($param{$_}) ne 'CODE'
    );
  }

  my $high_mark_level = delete $param{HighMark};
  my $low_mark_level  = delete $param{LowMark};
  my $high_event      = delete $param{ServerHigh};
  my $low_event       = delete $param{ServerLow};

  # this is ugly, but now its elegant :)  grep++
  my $using_watermarks = grep { defined $_ }
    ($high_mark_level, $low_mark_level, $high_event, $low_event);
  if ($using_watermarks > 0 and $using_watermarks != 4) {
    croak "If you use the Mark settings, you must define all four";
  }

  $high_event = sub { } unless defined $high_event;
  $low_event  = sub { } unless defined $low_event;

  my $conn_callback       = delete $param{Connected};
  my $conn_error_callback = delete $param{ConnectError};
  my $disc_callback       = delete $param{Disconnected};
  my $input_callback      = delete $param{ServerInput};
  my $error_callback      = delete $param{ServerError};
  my $flush_callback      = delete $param{ServerFlushed};
  my $start_callback      = delete $param{Started};
  my $filter              = delete $param{Filter};

  # Extra states.

  my $inline_states = delete $param{InlineStates};
  $inline_states = {} unless defined $inline_states;

  my $package_states = delete $param{PackageStates};
  $package_states = [] unless defined $package_states;

  my $object_states = delete $param{ObjectStates};
  $object_states = [] unless defined $object_states;

  croak "InlineStates must be a hash reference"
    unless ref($inline_states) eq 'HASH';

  croak "PackageStates must be a list or array reference"
    unless ref($package_states) eq 'ARRAY';

  croak "ObjectStates must be a list or array reference"
    unless ref($object_states) eq 'ARRAY';

  # Errors.

  croak "$mi requires a ServerInput parameter" unless defined $input_callback;

  foreach (sort keys %param) {
    carp "$mi doesn't recognize \"$_\" as a parameter";
  }

  # Defaults.

  $session_type = 'POE::Session' unless defined $session_type;
  if (defined($session_params) && ref($session_params)) {
    if (ref($session_params) ne 'ARRAY') {
      croak "SessionParams must be an array reference";
    }
  } else {
    $session_params = [ ];
  }

  $address = '127.0.0.1' unless defined $address;

  $conn_error_callback = \&_default_error unless defined $conn_error_callback;
  $error_callback      = \&_default_io_error unless defined $error_callback;

  $disc_callback  = sub {} unless defined $disc_callback;
  $conn_callback  = sub {} unless defined $conn_callback;
  $flush_callback = sub {} unless defined $flush_callback;
  $start_callback = sub {} unless defined $start_callback;

  # Spawn the session that makes the connection and then interacts
  # with what was connected to.

  return $session_type->create
    ( @$session_params,
      inline_states =>
      { _start => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];
          $heap->{shutdown_on_error} = 1;
          $kernel->alias_set( $alias ) if defined $alias;
          $kernel->yield( 'reconnect' );
          $start_callback->(@_);
        },

        # To quiet ASSERT_STATES.
        _stop   => sub { },
        _child  => sub { },

        reconnect => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];

          $heap->{shutdown} = 0;
          $heap->{connected} = 0;

          # Tentative patch to re-establish the alias upon reconnect.
          # Necessary because otherwise the alias goes away for good.
          # Unfortunately, there is a gap where the alias may not be
          # set, and any events dispatched then will be dropped.
          $kernel->alias_set( $alias ) if defined $alias;

          $heap->{server} = POE::Wheel::SocketFactory->new
            ( RemoteAddress => $address,
              RemotePort    => $port,
              SocketDomain  => $domain,
              BindAddress   => $bind_address,
              BindPort      => $bind_port,
              SuccessEvent  => 'got_connect_success',
              FailureEvent  => 'got_connect_error',
            );
          $_[KERNEL]->alarm_remove( delete $heap->{ctimeout_id} )
            if exists $heap->{ctimeout_id};
          $heap->{ctimeout_id} = $_[KERNEL]->alarm_set
            ( got_connect_timeout => time + $ctimeout
            ) if defined $ctimeout;
        },

        connect => sub {
          my ($new_address, $new_port) = @_[ARG0, ARG1];
          $address = $new_address if defined $new_address;
          $port    = $new_port    if defined $new_port;
          $_[KERNEL]->yield("reconnect");
        },

        got_connect_success => sub {
          my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

          $kernel->alarm_remove( delete $heap->{ctimeout_id} )
            if exists $heap->{ctimeout_id};

          # Ok to overwrite like this as of 0.13.
          $_[HEAP]->{server} = POE::Wheel::ReadWrite->new
            ( Handle       => $socket,
              Driver       => POE::Driver::SysRW->new(),
              Filter       => _get_filter($filter),
              InputEvent   => 'got_server_input',
              ErrorEvent   => 'got_server_error',
              FlushedEvent => 'got_server_flush',
              do {
                  $using_watermarks ? return (
                    HighMark => $high_mark_level,
                    HighEvent => 'got_high',
                    LowMark => $low_mark_level,
                    LowEvent => 'got_low',
                  ) : ();
                },
            );

          $heap->{connected} = 1;
          $conn_callback->(@_);
        },
        got_high => $high_event,
        got_low => $low_event,

        got_connect_error => sub {
          my $heap = $_[HEAP];
          $_[KERNEL]->alarm_remove( delete $heap->{ctimeout_id} )
            if exists $heap->{ctimeout_id};
          $heap->{connected} = 0;
          $conn_error_callback->(@_);
          delete $heap->{server};
        },

        got_connect_timeout => sub {
          my $heap = $_[HEAP];
          $heap->{connected} = 0;
          $_[KERNEL]->alarm_remove( delete $heap->{ctimeout_id} )
            if exists $heap->{ctimeout_id};
          $! = ETIMEDOUT;
          @_[ARG0,ARG1,ARG2] = ('connect', $!+0, $!);
          $conn_error_callback->(@_);
          delete $heap->{server};
        },

        got_server_error => sub {
          $error_callback->(@_);
          if ($_[HEAP]->{shutdown_on_error}) {
            $_[KERNEL]->yield("shutdown");
            $_[HEAP]->{got_an_error} = 1;
          }
        },

        got_server_input => sub {
          my $heap = $_[HEAP];
          return if $heap->{shutdown};
          $input_callback->(@_);
        },

        got_server_flush => sub {
          my $heap = $_[HEAP];
          $flush_callback->(@_);
          if ($heap->{shutdown}) {
            delete $heap->{server};
            $disc_callback->(@_);
          }
        },

        shutdown => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];
          $heap->{shutdown} = 1;

          $kernel->alarm_remove( delete $heap->{ctimeout_id} )
            if exists $heap->{ctimeout_id};

          if ($heap->{connected}) {
            $heap->{connected} = 0;
            if (defined $heap->{server}) {
              if (
                $heap->{got_an_error} or
                not $heap->{server}->get_driver_out_octets()
              ) {
                delete $heap->{server};
                $disc_callback->(@_);
              }
            }
          }
          else {
            delete $heap->{server};
          }

          $kernel->alias_remove($alias) if defined $alias;
        },

        # User supplied states.
        %$inline_states,
      },

      # User arguments.
      args => $args,

      # User supplied states.
      package_states => $package_states,
      object_states  => $object_states,
    )->ID;
}

sub _get_filter {
  my $filter = shift;
  if (ref $filter eq 'ARRAY') {
    my @filter_args = @$filter;
    $filter = shift @filter_args;
    return $filter->new(@filter_args);
  } elsif (ref $filter) {
    return $filter->clone();
  } elsif (!defined($filter)) {
    return POE::Filter::Line->new();
  } else {
    return $filter->new();
  }
}

# The default error handler logs to STDERR and shuts down the socket.

sub _default_error {
  unless ($_[ARG0] eq "read" and ($_[ARG1] == 0 or $_[ARG1] == ECONNRESET)) {
    warn(
      'Client ', $_[SESSION]->ID, " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
    );
  }
  delete $_[HEAP]->{server};
}

sub _default_io_error {
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  $error = "Normal disconnection" unless $errno;
  warn('Client ', $_[SESSION]->ID, " got $syscall error $errno ($error)\n");
  $_[KERNEL]->yield("shutdown");
}

1;

__END__

=head1 NAME

POE::Component::Client::TCP - a simplified TCP client

=head1 SYNOPSIS

  use POE qw(Component::Client::TCP);

  # Basic usage.

  POE::Component::Client::TCP->new
    ( RemoteAddress => "127.0.0.1",
      RemotePort    => "chargen",
      Domain        => AF_INET,        # Optional.
      Alias         => $session_alias  # Optional.
      ServerInput   => sub {
        my $input = $_[ARG0];
        print "from server: $input\n";
      }
    );

  # Complete usage.

  my $session_id = POE::Component::Client::TCP->new
    ( RemoteAddress  => "127.0.0.1",
      RemotePort     => "chargen",
      BindAddress    => "127.0.0.1",
      BindPort       => 8192,
      Domain         => AF_INET,        # Optional.
      Alias          => $session_alias  # Optional.
      ConnectTimeout => 5,              # Seconds; optional.

      SessionType   => "POE::Session::Abc",           # Optional.
      SessionParams => [ options => { debug => 1 } ], # Optional.

      Started        => \&handle_starting,   # Optional.
      Args           => [ "arg0", "arg1" ],  # Optional.  Start args.

      Connected      => \&handle_connect,
      ConnectError   => \&handle_connect_error,
      Disconnected   => \&handle_disconnect,

      ServerInput    => \&handle_server_input,
      ServerError    => \&handle_server_error,
      ServerFlushed  => \&handle_server_flush,

      Filter         => "POE::Filter::Something",

      InlineStates   => { ... },
      PackageStates  => [ ... ],
      ObjectStates   => [ ... ],
    );

  # Sample callbacks.

  sub handle_start {
    my @args = @_[ARG0..$#_];
  }

  sub handle_connect {
    my ($socket, $peer_address, $peer_port) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_connect_error {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_disconnect {
    # no special parameters
  }

  sub handle_server_input {
    my $input_record = $_[ARG0];
  }

  sub handle_server_error {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_server_flush {
    # no special parameters
  }

  # Reserved HEAP variables:

  $heap->{server}    = ReadWrite wheel representing the server.
  $heap->{shutdown}  = Shutdown flag (check to see if shutting down).
  $heap->{connected} = Connected flag (check to see if session is connected).
  $heap->{shutdown_on_error} = Automatically disconnect on error.

  # Accepted public events.

  $kernel->yield( "connect", $host, $port )  # connect to a new host/port
  $kernel->yield( "reconnect" )  # reconnect to the previous host/port
  $kernel->yield( "shutdown" )   # shut down a connection gracefully

  # Responding to a server.

  $heap->{server}->put(@things_to_send);

=head1 DESCRIPTION

The TCP client component hides the steps needed to create a client
using Wheel::SocketFactory and Wheel::ReadWrite.  The steps aren't
many, but they're still tiresome after a while.

POE::Component::Client::TCP supplies common defaults for most
callbacks and handlers.  The authors hope that clients can be created
with as little work as possible.

=head1 Constructor Parameters

=over

=item new

The new() method can accept quite a lot of parameters.  It will return
the session ID of the accecptor session.  One must use callbacks to 
check for errors rather than the return value of new().

=back

=over 2

=item Alias

Alias is an optional component alias.  It's used to post events to the
TCP client component from other sessions.  The most common use of
Alias is to allow a client component to receive "shutdown" and
"reconnect" events from a user interface session.

=item SessionType

SessionType specifies what type of sessions will be created within
the TCP server.  It must be a scalar value.

  SessionType => "POE::Session::MultiDispatch"

SessionType is optional.  The component will supply a "POE::Session"
type if none is specified.

=item SessionParams

Initialize parameters to be passed to the SessionType when it is created.
This must be an array reference.

  SessionParams => [ options => { debug => 1, trace => 1 } ],

It is important to realize that some of the arguments to SessionHandler
may get clobbered when defining them for your SessionHandler.  It is
advised that you stick to defining arguments in the "options" hash such
as trace and debug. See L<POE::Session> for an example list of options.

=item Args ARRAYREF

Args passes the contents of a ARRAYREF to the Started callback via
@_[ARG0..$#_].  It allows a program to pass extra information to the
session created to handle the client connection.

=item BindAddress

=item BindPort

Specifies the local interface address and/or port to bind to before
connecting.  This allows the client's connection to come from specific
addresses on a multi-host system.

=item ConnectError

ConnectError is an optional callback to handle SocketFactory errors.
These errors happen when a socket can't be created or connected to a
remote host.

ConnectError must contain a subroutine reference.  The subroutine will
be called as a SocketFactory error handler.  In addition to the usual
POE event parameters, ARG0 will contain the name of the syscall that
failed.  ARG1 will contain the numeric version of $! after the
failure, and ARG2 will contain $!'s string version.

Depending on the nature of the error and the type of client, it may be
useful to post a reconnect event from ConnectError's callback.

  sub handle_connect_error {
    $_[KERNEL]->delay( reconnect => 60 );
  }

The component will shut down after ConnectError if a reconnect isn't
requested.

=item Connected

Connected is an optional callback to notify a program that
SocketFactory succeeded.  This is an advisory callback, and it should
not create a ReadWrite wheel itself.  The component will handle
setting up ReadWrite.

ARG0 contains a socket handle.  It's not necessary to save this under
most circumstances.  ARG1 and ARG2 contain the peer address and port
as returned from getpeername().

=item ConnectTimeout

ConnectTimeout is the maximum time in seconds to wait for a connection
to be established.  If it is omitted, Client::TCP relies on the
operating system to abort stalled connect() calls.

Upon a connection timeout, Client::TCP will send a ConnectError event.
Its ARG0 will be 'connect' and ARG1 will be the POSIX/Errno ETIMEDOUT
value.

=item Disconnected

Disconnected is an optional callback to notify a program that an
established server connection has shut down.  It has no special
parameters.

For persistent connections, such as MUD bots or long-running services,
a useful thing to do from a Disconnected handler is reconnect.  For
example, this reconnects after waiting a minute:

  sub handle_disconnect {
    $_[KERNEL]->delay( reconnect => 60 );
  }

The component will shut down after disconnecting if a reconnect isn't
requested.

=item Domain

Specifies the domain within which communication will take place.  It
selects the protocol family which should be used.  Currently supported
values are AF_INET, AF_INET6, PF_INET or PF_INET6.  This parameter is
optional and will default to AF_INET if omitted.

Note: AF_INET6 and PF_INET6 are supplied by the Socket6 module, which
is available on the CPAN.  You must have Socket6 loaded before
POE::Component::Server::TCP will create IPv6 sockets.

=item Filter

Filter specifies the type of filter that will parse input from a
server.  It may either be a scalar, a list reference or a POE::Filter
reference.
If it is a scalar, it will contain a POE::Filter class name.

  Filter => "POE::Filter::Line",

If it is a list reference, the first item in the list will be a 
POE::Filter class name, and the remaining items will be constructor
parameters for the filter.  For example, this changes the line separator
to a vertical pipe:

  Filter => [ "POE::Filter::Line", Literal => "|" ],

If it is an object, it will be clone()'d.

  Filter => POE::Filter::Line->new()

Filter is optional.  The component will supply a "POE::Filter::Line"
instance none is specified.  If you supply a different value for
Filter, then you must also C<use> that filter class.

=item InlineStates

InlineStates holds a hashref of inline coderefs to handle events.  The
hashref is keyed on event name.  For more information, see
POE::Session's create() method.

=item ObjectStates

ObjectStates holds a list reference of objects and the events they
handle.  For more information, see POE::Session's create() method.

=item PackageStates

PackageStates holds a list reference of Perl package names and the
events they handle.  For more information, see POE::Session's create()
method.

=item RemoteAddress

RemoteAddress contains the address to connect to.  It is required and
may be a host name ("poe.perl.org") a dotted quad ("127.0.0.1") or a
packed socket address.

=item RemotePort

RemotePort contains the port to connect to.  It is required and may be
a service name ("echo") or number (7).

=item ServerError

ServerError is an optional callback to notify a program that an
established server connection has encountered some kind of error.
Like with ConnectError, it accepts the traditional error parameters:

ARG0 contains the name of the syscall that failed.  ARG1 contains the
numeric failure code from $!.  ARG2 contains the string version of $!.

The component will shut down after a server error if a reconnect isn't
requested.

=item ServerFlushed

ServerFlushed is an optional callback to notify a program that
ReadWrite's output buffers have completely flushed.  It has no special
parameters.

The component will shut down after a server flush if $heap->{shutdown}
is set.

=item ServerInput

ServerInput is a required callback.  It is called for each input
record received from a server.  ARG0 contains the input record, the
format of which is determined by POE::Component::Client::TCP's Filter
parameter.

The ServerInput function will stop being called when $heap->{shutdown}
is true.

=item Started

Started is an optional callback.  It is called after Client::TCP is
initialized but before a connection has been established.

The Args parameter can be used to pass initialization values to the
Started callback, eliminating the need for closures to get values into
the component.  These values are included in the @_[ARG0..$#_]
parameters.

=back

=head1 Public Events

=over 2

=item connect

Cause the TCP client to connect, optionally providing a new RemoteHost
and RemotePort (which will also be used for subsequent "reconnect"s.
If the client is already connected, it will disconnect harshly, as
with reconnect, discarding any pending input or output.

=item reconnect

Instruct the TCP client component to reconnect to the server.  If it's
already connected, it will disconnect harshly, discarding any pending
input or output data.

=item shutdown

When a Client::TCP component receives a shutdown event, it initiates a
graceful shutdown.  Any subsequent server input will be ignored, and
any pending output data will be flushed.  Once the connection is dealt
with, the component will self-destruct.

=back

=head1 SEE ALSO

POE::Component::Server::TCP, POE::Wheel::SocketFactory,
POE::Wheel::ReadWrite, POE::Filter

=head1 CAVEATS

This may not be suitable for complex client tasks.  After a point, it
becomes easier to roll a custom client using POE::Wheel::SocketFactory
and POE::Wheel::ReadWrite.

This looks nothing like what Ann envisioned.

=head1 AUTHORS & COPYRIGHTS

POE::Component::Client::TCP is Copyright 2001-2006 by Rocco Caputo.
All rights are reserved.  POE::Component::Client::TCP is free
software, and it may be redistributed and/or modified under the same
terms as Perl itself.

POE::Component::Client::TCP is based on code, used with permission,
from Ann Barcomb E<lt>kudra@domaintje.comE<gt>.

POE::Component::Client::TCP is based on code, used with permission,
from Jos Boumans E<lt>kane@cpan.orgE<gt>.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Redocument.
