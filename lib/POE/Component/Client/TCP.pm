# $Id$

package POE::Component::Client::TCP;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(carp croak);

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
  my $alias   = delete $param{Alias};
  my $address = delete $param{RemoteAddress};
  my $port    = delete $param{RemotePort};

  foreach ( qw( Connected ConnectError Disconnected ServerInput
                ServerError ServerFlushed
              )
          ) {
    croak "$_ must be a coderef"
      if defined($param{$_}) and ref($param{$_}) ne 'CODE';
  }

  my $conn_callback       = delete $param{Connected};
  my $conn_error_callback = delete $param{ConnectError};
  my $disc_callback       = delete $param{Disconnected};
  my $input_callback      = delete $param{ServerInput};
  my $error_callback      = delete $param{ServerError};
  my $flush_callback      = delete $param{ServerFlushed};
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

  croak "ObjectsStates must be a list or array reference"
    unless ref($object_states) eq 'ARRAY';

  # Errors.

  croak "$mi requires a ServerInput parameter" unless defined $input_callback;

  # Defaults.

  my @filter_args;
  $address = '127.0.0.1' unless defined $address;
  unless (defined $filter) {
    $filter = "POE::Filter::Line";
  }
  elsif (ref($filter) eq 'ARRAY') {
    @filter_args = @$filter;
    $filter      = shift @filter_args;
  }

  $conn_error_callback = \&_default_error unless defined $conn_error_callback;
  $error_callback      = \&_default_error unless defined $error_callback;

  $disc_callback  = sub {} unless defined $disc_callback;
  $conn_callback  = sub {} unless defined $conn_callback;
  $flush_callback = sub {} unless defined $flush_callback;

  # Spawn the session that makes the connection and then interacts
  # with what was connected to.

  POE::Session->create
    ( inline_states =>
      { _start => sub {
          my $kernel = $_[KERNEL];
          $kernel->alias_set( $alias ) if defined $alias;
          $kernel->yield( 'reconnect' );
        },

        # To quiet ASSERT_STATES.
        _stop   => sub { },
        _child  => sub { },
        _signal => sub { 0 },

        reconnect => sub {
          my $heap = $_[HEAP];

          $heap->{shutdown} = 0;
          $heap->{connected} = 0;

          $heap->{server} = POE::Wheel::SocketFactory->new
            ( RemoteAddress => $address,
              RemotePort    => $port,
              SuccessEvent  => 'got_connect_success',
              FailureEvent  => 'got_connect_error',
            );
        },

        got_connect_success => sub {
          my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

          # Ok to overwrite like this as of 0.13.
          $_[HEAP]->{server} = POE::Wheel::ReadWrite->new
            ( Handle       => $socket,
              Driver       => POE::Driver::SysRW->new( BlockSize => 4096 ),
              Filter       => $filter->new(@filter_args),
              InputEvent   => 'got_server_input',
              ErrorEvent   => 'got_server_error',
              FlushedEvent => 'got_server_flush',
            );

          $heap->{connected} = 1;
          $conn_callback->(@_);
        },

        got_connect_error => sub {
          my $heap = $_[HEAP];
          $heap->{connected} = 0;
          $conn_error_callback->(@_);
          delete $heap->{server};
        },

        got_server_error => sub {
          my ($heap, $operation, $errnum) = @_[HEAP, ARG0, ARG1];

          $heap->{connected} = 0;

          # Read error 0 is disconnect.
          if ($operation eq 'read' and $errnum == 0) {
            $disc_callback->(@_);
          }
          else {
            $error_callback->(@_);
          }

          delete $heap->{server};
        },

        got_server_input => sub {
          my $heap = $_[HEAP];
          return if $heap->{shutdown};
          $input_callback->(@_);
        },

        got_server_flush => sub {
          my $heap = $_[HEAP];
          $flush_callback->(@_);
          delete $heap->{server} if $heap->{shutdown};
        },

        shutdown => sub {
          my $heap = $_[HEAP];
          $heap->{shutdown} = 1;

          if ($heap->{connected}) {
            if (defined $heap->{server}) {
              delete $heap->{server}
                unless $heap->{server}->get_driver_out_octets();
              $disc_callback->(@_);
            }
          }
          else {
            delete $heap->{server};
          }
        },

        # User supplied states.
        %$inline_states,
      },

      # User supplied states.
      package_states => $package_states,
      object_states  => $object_states,
    );
}

# The default error handler logs to STDERR and shuts down the socket.

sub _default_error {
  warn( 'Client ', $_[SESSION]->ID,
        " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
      );
  delete $_[HEAP]->{server};
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
      ServerInput   => sub {
        my $input = $_[ARG0];
        print "from server: $input\n";
      }
    );

  # Complete usage.

  POE::Component::Client::TCP->new
    ( RemoteAddress => "127.0.0.1",
      RemotePort    => "chargen",

      Connected     => \&handle_connect,
      ConnectError  => \&handle_connect_error,
      Disconnected  => \&handle_disconnect,

      ServerInput   => \&handle_server_input,
      ServerError   => \&handle_server_error,
      ServerFlushed => \&handle_server_flush,

      Filter        => "POE::Filter::Something",

      InlineStates  => { ... },
      PackageStates => [ ... ],
      ObjectStates  => [ ... ],
    );

  # Sample callbacks.

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

  $heap->{server}   = ReadWrite wheel representing the server
  $heap->{shutdown} = shutdown flag (check to see if shutting down)
  $heap->{connected} = connected flag (check to see if session is connected)

  # Accepted public events.

  $kernel->yield( "shutdown" )   # shut down a connection
  $kernel->yield( "reconnect" )  # reconnect to a server

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

=over 2

=item Alias

Alias is an optional component alias.  It's used to post events to the
TCP client component from other sessions.  The most common use of
Alias is to allow a client component to receive "shutdown" and
"reconnect" events from a user interface session.

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

=item Filter

Filter specifies the type of filter that will parse input from a
server.  It may either be a scalar or a list reference.  If it is a
scalar, it will contain a POE::Filter class name.  If it is a list
reference, the first item in the list will be a POE::Filter class
name, and the remaining items will be constructor parameters for the
filter.

Filter is optional.  The component will supply a "POE::Filter::Line"
instance none is specified.

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

=back

=head1 Public Events

=over 2

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

This may not be suitable for complex client tasks.

This looks nothing like what Ann envisioned.

=head1 AUTHORS & COPYRIGHTS

POE::Component::Client::TCP is Copyright 2001 by Rocco Caputo.  All
rights are reserved.  POE::Component::Client::TCP is free software,
and it may be redistributed and/or modified under the same terms as
Perl itself.

POE::Component::Client::TCP is based on code, used with permission,
from Ann Barcomb E<lt>kudra@domaintje.comE<gt>.

POE::Component::Client::TCP is based on code, used with permission,
from Jos Boumans E<lt>kane@cpan.orgE<gt>.

=cut
