# $Id$

package POE::Component::Server::TCP;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(carp croak);
use Socket qw(INADDR_ANY inet_ntoa);

# Explicit use to import the parameter constants.
use POE::Session;
use POE::Driver::SysRW;
use POE::Filter::Line;
use POE::Wheel::ReadWrite;
use POE::Wheel::SocketFactory;

# Create the server.  This is just a handy way to encapsulate
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
  croak "$mi needs a Port parameter" unless exists $param{Port};

  # Extract parameters.
  my $alias   = delete $param{Alias};
  my $address = delete $param{Address};
  my $port    = delete $param{Port};

  foreach ( qw( Acceptor Error ClientInput ClientConnected
                ClientDisconnected ClientError ClientFlushed
              )
          ) {
    croak "$_ must be a coderef"
      if defined($param{$_}) and ref($param{$_}) ne 'CODE';
  }

  my $accept_callback = delete $param{Acceptor};
  my $error_callback  = delete $param{Error};

  my $client_input    = delete $param{ClientInput};

  # Acceptor and ClientInput are mutually exclusive.
  croak "$mi needs either an Acceptor or a ClientInput but not both"
    unless defined($accept_callback) xor defined($client_input);

  # Make sure ClientXyz are accompanied by ClientInput.
  unless (defined($client_input)) {
    foreach (grep /^Client/, keys %param) {
      croak "$_ not permitted without ClientInput";
    }
  }

  my @client_filter_args;
  my $client_connected    = delete $param{ClientConnected};
  my $client_disconnected = delete $param{ClientDisconnected};
  my $client_error        = delete $param{ClientError};
  my $client_filter       = delete $param{ClientFilter};
  my $client_flushed      = delete $param{ClientFlushed};

  # Defaults.

  $address = INADDR_ANY unless defined $address;

  $error_callback = \&_default_server_error unless defined $error_callback;

  if (defined $client_input) {
    unless (defined $client_filter) {
      $client_filter      = "POE::Filter::Line";
      @client_filter_args = ();
    }
    elsif (ref($client_filter) eq 'ARRAY') {
      @client_filter_args = @$client_filter;
      $client_filter      = shift @client_filter_args;
    }

    $client_error  = \&_default_client_error  unless defined $client_error;
    $client_connected    = sub {} unless defined $client_connected;
    $client_disconnected = sub {} unless defined $client_disconnected;
    $client_flushed      = sub {} unless defined $client_flushed;

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

    # Revise the acceptor callback so it spawns a session.

    $accept_callback = sub {
      my ($socket, $remote_addr, $remote_port) = @_[ARG0, ARG1, ARG2];
      POE::Session->create
        ( inline_states =>
          { _start => sub {
              my ( $kernel, $session, $heap ) = @_[KERNEL, SESSION, HEAP];

              $heap->{shutdown}    = 0;
              $heap->{remote_ip}   = inet_ntoa($remote_addr);
              $heap->{remote_port} = $remote_port;

              $heap->{client} = POE::Wheel::ReadWrite->new
                ( Handle       => $socket,
                  Driver       => POE::Driver::SysRW->new( BlockSize => 4096 ),
                  Filter       => $client_filter->new(@client_filter_args),
                  InputEvent   => 'tcp_server_got_input',
                  ErrorEvent   => 'tcp_server_got_error',
                  FlushedEvent => 'tcp_server_got_flush',
                );

              $client_connected->(@_);
            },

            # To quiet ASSERT_STATES.
            _child  => sub { },
            _signal => sub { 0 },

            tcp_server_got_input => sub {
              my $heap = $_[HEAP];
              return if $heap->{shutdown};
              $client_input->(@_);
            },
            tcp_server_got_error => sub {
              my ($heap, $operation, $errnum) = @_[HEAP, ARG0, ARG1];

              $heap->{shutdown} = 1;

              # Read error 0 is disconnect.
              if ($operation eq 'read' and $errnum == 0) {
                $client_disconnected->(@_);
              }
              else {
                $client_error->(@_);
              }

              delete $heap->{client};
            },
            tcp_server_got_flush => sub {
              my $heap = $_[HEAP];
              $client_flushed->(@_);
              delete $heap->{client} if $heap->{shutdown};
            },
            shutdown => sub {
              my $heap = $_[HEAP];
              $heap->{shutdown} = 1;
              if (defined $heap->{client}) {
                delete $heap->{client}
                  unless $heap->{client}->get_driver_out_octets();
              }
            },
            _stop => $client_disconnected,

            tcp_server_got_flushed => sub {
              my ($kernel, $heap) = @_[KERNEL, HEAP];
              delete $heap->{client} if $heap->{shutdown};
            },

            # User supplied states.
            %$inline_states
          },

          # More user supplied states.
          package_states => $package_states,
          object_states  => $object_states,
        );
    };
  };

  # Complain about strange things we're given.
  foreach (sort keys %param) {
    carp "$mi doesn't recognize \"$_\" as a parameter";
  }

  # Create the session, at long last.  This is done inline so that
  # closures can customize it.

  POE::Session->create
    ( inline_states =>
      { _start =>
        sub {
          if (defined $alias) {
            $_[HEAP]->{alias} = $alias;
            $_[KERNEL]->alias_set( $alias );
          }

          $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new
            ( BindPort     => $port,
              BindAddress  => $address,
              Reuse        => 'yes',
              SuccessEvent => 'tcp_server_got_connection',
              FailureEvent => 'tcp_server_got_error',
            );
        },

        # Catch an error.
        tcp_server_got_error => $error_callback,

        # We accepted a connection.  Do something with it.
        tcp_server_got_connection => $accept_callback,

        # Shut down.
        shutdown => sub {
          delete $_[HEAP]->{listener};
          $_[KERNEL]->alias_remove( $_[HEAP]->{alias} )
            if defined $_[HEAP]->{alias};
        },

        # Dummy states to prevent warnings.
        _signal => sub { return 0 },
        _stop   => sub { return 0 },
        _child  => sub { },
        _signal => sub { 0 },
      },
    );

  # Return undef so nobody can use the POE::Session reference.  This
  # isn't very friendly, but it saves grief later.
  undef;
}

# The default server error handler logs to STDERR and shuts down the
# server.

sub _default_server_error {
  warn( 'Server ', $_[SESSION]->ID,
        " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
      );
  delete $_[HEAP]->{listener};
}

# The default client error handler logs to STDERR and shuts down the
# server.

sub _default_client_error {
  warn( 'Client ', $_[SESSION]->ID,
        " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
      );
  delete $_[HEAP]->{client};
}

1;

__END__

=head1 NAME

POE::Component::Server::TCP - a simplified TCP server

=head1 SYNOPSIS

  use POE qw(Component::Server::TCP);

  # First form just accepts connections.

  POE::Component::Server::TCP->new
    ( Port     => $bind_port,
      Address  => $bind_address,    # Optional.
      Acceptor => \&accept_handler,
      Error    => \&error_handler,  # Optional.
    );

  # Second form accepts and handles connections.

  POE::Component::Server::TCP->new
    ( Port     => $bind_port,
      Address  => $bind_address,    # Optional.
      Acceptor => \&accept_handler, # Optional.
      Error    => \&error_handler,  # Optional.

      ClientInput        => \&handle_client_input,      # Required.
      ClientConnected    => \&handle_client_connect,    # Optional.
      ClientDisconnected => \&handle_client_disconnect, # Optional.
      ClientError        => \&handle_client_error,      # Optional.
      ClientFlushed      => \&handle_client_flush,      # Optional.
      ClientFilter       => "POE::Filter::Xyz",         # Optional.

      # Optionally define other states for the client session.
      InlineStates  => { ... },
      PackageStates => [ ... ],
      ObjectStates  => [ ... ],
    );

  # Call signatures for handlers.

  sub accept_handler {
    my ($socket, $remote_address, $remote_port) = @_[ARG0, ARG1, ARG2];
  }

  sub error_handler {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_client_input {
    my $input_record = $_[ARG0];
  }

  sub handle_client_error {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_client_connect {
    # no special parameters
  }

  sub handle_client_disconnect {
    # no special parameters
  }

  sub handle_client_flush {
    # no special parameters
  }

  # Reserved HEAP variables:

  $heap->{listener}    = SocketFactory (only Acceptor and Error callbacks)
  $heap->{client}      = ReadWrite     (only in ClientXyz callbacks)
  $heap->{remote_ip}   = remote IP address in dotted form
  $heap->{remote_port} = remote port
  $heap->{remote_addr} = packed remote address and port
  $heap->{shutdown}    = shutdown flag (check to see if shutting down)

  # Accepted public events.

  $kernel->yield( "shutdown" )           # initiate shutdown in a connection
  $kernel->post( server => "shutdown" )  # stop listening for connections

=head1 DESCRIPTION

The TCP server component hides the steps needed to create a server
using Wheel::SocketFactory.  The steps aren't many, but they're still
tiresome after a while.

POE::Component::Server::TCP supplies common defaults for most
callbacks and handlers.  The authors hope that servers can be created
with as little work as possible.

Constructor parameters:

=over 2

=item Acceptor

Acceptor is a coderef which will be called to handle accepted sockets.
The coderef receives its parameters directly from SocketFactory's
SuccessEvent.  ARG0 is the accepted socket handle, suitable for giving
to a ReadWrite wheel.  ARG1 and ARG2 contain the packed remote address
and numeric port, respectively.  ARG3 is the SocketFactory wheel's ID.

  Acceptor => \&accept_handler

Acceptor and ClientInput are mutually exclusive.  Enabling one
prohibits the other.

=item Address

Address is the optional interface address the TCP server will bind to.
It defaults to INADDR_ANY.

  Address => '127.0.0.1'

It's passed directly to SocketFactory's BindAddress parameter, so it
can be in whatever form SocketFactory supports.  At the time of this
writing, that's a dotted quad, a host name, or a packed Internet
address.

=item Alias

Alias is an optional name by which this server may be referenced.
It's used to pass events to a TCP server from other sessions.

  Alias => 'chargen'

Later on, the 'chargen' service can be shut down with:

  $kernel->post( chargen => 'shutdown' );

=item ClientConnected

ClientConnected is a coderef that will be called for each new client
connection.  ClientConnected callbacks receive the usual POE
parameters, but nothing special is included.

=item ClientDisconnected

ClientDisconnected is a coderef that will be called for each client
disconnection.  ClientDisconnected callbacks receive the usual POE
parameters, but nothing special is included.

=item ClientError

ClientError is a coderef that will be called whenever an error occurs
on a socket.  It receives the usual error handler parameters: ARG0 is
the name of the function that failed.  ARG1 is the numeric failure
code ($! in numeric context).  ARG2 is the string failure code ($! in
string context).

If ClientError is omitted, a default one will be provided.  The
default error handler logs the error to STDERR and closes the
connection.

=item ClientFilter

ClientFilter specifies the type of filter that will parse input from
each client.  It may either be a scalar or a list reference.  If it is
a scalar, it will contain a POE::Filter class name.  If it is a list
reference, the first item in the list will be a POE::Filter class
name, and the remaining items will be constructor parameters for the
filter.

ClientFilter is optional.  The component will supply a
"POE::Filter::Line" instance none is specified.

=item ClientInput

ClientInput is a coderef that will be called to handle client input.
The callback receives its parameters directyl from ReadWrite's
InputEvent.  ARG0 is the input record, and ARG1 is the wheel's unique
ID.

  ClientInput => \&input_handler

ClientInput and Acceptor are mutually exclusive.  Enabling one
prohibits the other.

=item Error

Error is an optional coderef which will be called to handle server
socket errors.  The coderef is used as POE::Wheel::SocketFactory's
FailureEvent, so it accepts the same parameters.  If it is omitted, a
default error handler will be provided.  The default handler will log
the error to STDERR and shut down the server.

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

=item Port

Port is the port the listening socket will be bound to.  It defaults
to INADDR_ANY, which usually lets the operating system pick a port.

  Port => 30023

=back

=head1 EVENTS

It's possible to manipulate a TCP server component from some other
session.  This is useful for shutting them down, and little else so
far.

=over 2

=item shutdown

Shuts down the TCP server.  This entails destroying the SocketFactory
that's listening for connections and removing the TCP server's alias,
if one is set.

=back

=head1 SEE ALSO

POE::Component::Client::TCP, POE::Wheel::SocketFactory,
POE::Wheel::ReadWrite, POE::Filter

=head1 CAVEATS

This is not suitable for complex tasks.  For example, you cannot
engage in a challenge-response with the client-- you can only reply to
the one message a client sends.

=head1 BUGS

This looks nothing like what Ann envisioned.

This component currently does not accept many of the options that
POE::Wheel::SocketFactory does.

This component will not bind to several addresses.  This may be a
limitation in SocketFactory.

This component needs more complex error handling which appends for
construction errors and replaces for runtime errors, instead of
replacing for all.

=head1 AUTHORS & COPYRIGHTS

POE::Component::Server::TCP is Copyright 2000-2001 by Rocco Caputo.
All rights are reserved.  POE::Component::Server::TCP is free
software, and it may be redistributed and/or modified under the same
terms as Perl itself.

POE::Component::Server::TCP is based on code, used with permission,
from Ann Barcomb E<lt>kudra@domaintje.comE<gt>.

POE::Component::Server::TCP is based on code, used with permission,
from Jos Boumans E<lt>kane@cpan.orgE<gt>.

=cut
