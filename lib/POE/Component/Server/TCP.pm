# $Id$

package POE::Component::Server::TCP;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use Carp qw(carp croak);
use Socket qw(INADDR_ANY inet_ntoa AF_UNIX PF_UNIX);
use Errno qw(ECONNABORTED ECONNRESET);

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
  my $domain  = delete $param{Domain};

  foreach (
    qw(
      Acceptor Error ClientInput ClientConnected ClientDisconnected
      ClientError ClientFlushed
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

  my (@client_filter_args, @client_infilter_args, @client_outfilter_args);
  my $client_connected    = delete $param{ClientConnected};
  my $client_disconnected = delete $param{ClientDisconnected};
  my $client_error        = delete $param{ClientError};
  my $client_filter       = delete $param{ClientFilter};
  my $client_infilter     = delete $param{ClientInputFilter};
  my $client_outfilter    = delete $param{ClientOutputFilter};
  my $client_flushed      = delete $param{ClientFlushed};
  my $args                = delete $param{Args};
  my $session_type        = delete $param{SessionType};
  my $session_params      = delete $param{SessionParams};

  # Defaults.

  $address = INADDR_ANY unless defined $address;

  $error_callback = \&_default_server_error unless defined $error_callback;

  $session_type = 'POE::Session' unless defined $session_type;
  if (defined($session_params) && ref($session_params)) {
    if (ref($session_params) ne 'ARRAY') {
      croak "SessionParams must be an array reference";
    }
  } else {
    $session_params = [ ];
  }

  if (defined $client_input) {
    if (defined $client_infilter and defined $client_outfilter) {

      @client_infilter_args  = ();
      @client_outfilter_args = ();

      if (ref($client_infilter) eq 'ARRAY') {
         @client_infilter_args = @$client_infilter;
	 $client_infilter      = shift @client_infilter_args;
      }

      if (ref($client_outfilter) eq 'ARRAY') {
         @client_outfilter_args = @$client_outfilter;
	 $client_outfilter      = shift @client_outfilter_args;
      }

      my $eval = eval {
	 (my $inmod  = $client_infilter)  =~ s!::!/!g;
	 (my $outmod = $client_outfilter) =~ s!::!/!g;
         require "$inmod.pm";
         require "$outmod.pm";
	 1;
      };

      if (!$eval and $@) {
        carp "Failed to load [$client_infilter] and [$client_outfilter]\n"
           . "Reason $@\nUsing defualts ";

        undef($client_infilter);
        undef($client_outfilter);
        $client_filter      = "POE::Filter::Line";
        @client_filter_args = ();
      }

    } else {
       undef($client_infilter);  # just to be safe in case one was defined
       undef($client_outfilter); # and the other wasn't

       unless (defined $client_filter) {
         $client_filter      = "POE::Filter::Line";
         @client_filter_args = ();
       }
       elsif (ref($client_filter) eq 'ARRAY') {
         @client_filter_args = @$client_filter;
         $client_filter      = shift @client_filter_args;
       }
    }

    $client_error  = \&_default_client_error unless defined $client_error;
    $client_connected    = sub {} unless defined $client_connected;
    $client_disconnected = sub {} unless defined $client_disconnected;
    $client_flushed      = sub {} unless defined $client_flushed;
    $args = [] unless defined $args;

    # Extra states.

    my $inline_states = delete $param{InlineStates};
    $inline_states = {} unless defined $inline_states;

    my $package_states = delete $param{PackageStates};
    $package_states = [] unless defined $package_states;

    my $object_states = delete $param{ObjectStates};
    $object_states = [] unless defined $object_states;

    my $shutdown_on_error = 1;
    if (exists $param{ClientShutdownOnError}) {
      $shutdown_on_error = delete $param{ClientShutdownOnError};
    }

    croak "InlineStates must be a hash reference"
      unless ref($inline_states) eq 'HASH';

    croak "PackageStates must be a list or array reference"
      unless ref($package_states) eq 'ARRAY';

    croak "ObjectsStates must be a list or array reference"
      unless ref($object_states) eq 'ARRAY';

    croak "Args must be an array reference"
      unless ref($args) eq 'ARRAY';

    # Revise the acceptor callback so it spawns a session.

    unless (defined $accept_callback) {
      $accept_callback = sub {
        my ($socket, $remote_addr, $remote_port) = @_[ARG0, ARG1, ARG2];
        $session_type->create
          ( @$session_params,
            inline_states =>
            { _start => sub {
                my ( $kernel, $session, $heap ) = @_[KERNEL, SESSION, HEAP];

                $heap->{shutdown} = 0;
                $heap->{shutdown_on_error} = $shutdown_on_error;

                # Unofficial UNIX support, suggested by Damir Dzeko.
                # Real UNIX socket support should go into a separate
                # module, but if that module only differs by four
                # lines of code it would be bad to maintain two
                # modules for the price of one.  One solution would be
                # to pull most of this into a base class and derive
                # TCP and UNIX versions from that.
                if (
                  defined $domain and
                  ($domain == AF_UNIX or $domain == PF_UNIX)
                ) {
                  $heap->{remote_ip} = "LOCAL";
                }
                elsif (length($remote_addr) == 4) {
                  $heap->{remote_ip} = inet_ntoa($remote_addr);
                }
                else {
                  $heap->{remote_ip} =
                    Socket6::inet_ntop($domain, $remote_addr);
                }

                $heap->{remote_port} = $remote_port;

                # Alter the filters depending whether they are
                # discrete input/output ones, or whether they are the
                # same.  It's useful to note that the input/output
                # filters may be changed at runtime.
                my @filters;
                if ($client_infilter) {
                  @filters = (
                    InputFilter  => $client_infilter->new(
                      @client_infilter_args
                    ),
                    OutputFilter => $client_outfilter->new(
                      @client_outfilter_args
                    ),
                  );
                }
                else {
                  @filters = (
                    Filter       => $client_filter->new(@client_filter_args),
                  );
                }

                $heap->{client} = POE::Wheel::ReadWrite->new(
                  Handle       => $socket,
                  Driver       => POE::Driver::SysRW->new(),
                  @filters,
                  InputEvent   => 'tcp_server_got_input',
                  ErrorEvent   => 'tcp_server_got_error',
                  FlushedEvent => 'tcp_server_got_flush',
                );

                $kernel->yield(tcp_server_client_connected => @_[ARG0 .. $#_]);
              },

              # To quiet ASSERT_STATES.
              _child  => sub { },

              tcp_server_client_connected => $client_connected,

              tcp_server_got_input => sub {
                return if $_[HEAP]->{shutdown};
                $client_input->(@_);
              },
              tcp_server_got_error => sub {
                unless ($_[ARG0] eq 'accept' and $_[ARG1] == ECONNABORTED) {
                  $client_error->(@_);
                  if ($_[HEAP]->{shutdown_on_error}) {
                    $_[HEAP]->{got_an_error} = 1;
                    $_[KERNEL]->yield("shutdown");
                  }
                }
              },
              tcp_server_got_flush => sub {
                my $heap = $_[HEAP];
                $client_flushed->(@_);
                if ($heap->{shutdown}) {
                  $client_disconnected->(@_);
                  delete $heap->{client};
                }
              },
              shutdown => sub {
                my $heap = $_[HEAP];
                $heap->{shutdown} = 1;
                if (defined $heap->{client}) {
                  if (
                    $heap->{got_an_error} or
                    not $heap->{client}->get_driver_out_octets()
                  ) {
                    $client_disconnected->(@_);
                    delete $heap->{client};
                  }
                }
              },
              _stop => sub {},

              # User supplied states.
              %$inline_states
            },

            # More user supplied states.
            package_states => $package_states,
            object_states  => $object_states,

            args => $args,
          );
      };
    }
  };

  # Complain about strange things we're given.
  foreach (sort keys %param) {
    carp "$mi doesn't recognize \"$_\" as a parameter";
  }

  # Create the session, at long last.  This is done inline so that
  # closures can customize it.

  $session_type->create
    ( @$session_params,
      inline_states =>
      { _start =>
          sub {
            if (defined $alias) {
              $_[HEAP]->{alias} = $alias;
              $_[KERNEL]->alias_set( $alias );
            }

            $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new
              ( BindPort     => $port,
                BindAddress  => $address,
                SocketDomain => $domain,
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
        _stop   => sub { return 0 },
        _child  => sub { },
      },

      args => $args,
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
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  unless ($syscall eq "read" and ($errno == 0 or $errno == ECONNRESET)) {
    $error = "(no error)" unless $errno;
    warn(
      'Client session ', $_[SESSION]->ID,
      " got $syscall error $errno ($error)\n"
    );
  }
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
      Domain   => AF_INET,          # Optional.
      Alias    => $session_alias,   # Optional.
      Acceptor => \&accept_handler,
      Error    => \&error_handler,  # Optional.
    );

  # Second form accepts and handles connections.

  POE::Component::Server::TCP->new
    ( Port     => $bind_port,
      Address  => $bind_address,      # Optional.
      Domain   => AF_INET,            # Optional.
      Alias    => $session_alias,     # Optional.
      Acceptor => \&accept_handler,   # Optional.
      Error    => \&error_handler,    # Optional.
      Args     => [ "arg0", "arg1" ], # Optional.

      SessionType   => "POE::Session::Abc",           # Optional.
      SessionParams => [ options => { debug => 1 } ], # Optional.

      ClientInput        => \&handle_client_input,      # Required.
      ClientConnected    => \&handle_client_connect,    # Optional.
      ClientDisconnected => \&handle_client_disconnect, # Optional.
      ClientError        => \&handle_client_error,      # Optional.
      ClientFlushed      => \&handle_client_flush,      # Optional.
      ClientFilter       => "POE::Filter::Xyz",         # Optional.
      ClientInputFilter  => "POE::Filter::Xyz",         # Optional.
      ClientOutputFilter => "POE::Filter::Xyz",         # Optional.
      ClientShutdownOnError => 0,                       # Optional.

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
  $heap->{shutdown_on_error} = Automatically disconnect on error.

  # Accepted public events.

  $kernel->yield( "shutdown" )           # initiate shutdown in a connection
  $kernel->post( server => "shutdown" )  # stop listening for connections

  # Responding to a client.

  $heap->{client}->put(@things_to_send);

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

Acceptor lets programmers rewrite the guts of Server::TCP entirely.
It disables the code that provides the /Client.*/ callbacks.

=item Address

Address is the optional interface address the TCP server will bind to.
It defaults to INADDR_ANY or INADDR6_ANY when using IPv4 or IPv6,
respectively.

  Address => '127.0.0.1'   # Localhost IPv4
  Address => "::1"         # Localhost IPv6

It's passed directly to SocketFactory's BindAddress parameter, so it
can be in whatever form SocketFactory supports.  At the time of this
writing, that's a dotted quad, an IPv6 address, a host name, or a
packed Internet address.

=item Alias

Alias is an optional name by which this server may be referenced.
It's used to pass events to a TCP server from other sessions.

  Alias => 'chargen'

Later on, the 'chargen' service can be shut down with:

  $kernel->post( chargen => 'shutdown' );

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

=item ClientConnected

ClientConnected is a coderef that will be called for each new client
connection.  ClientConnected callbacks receive the usual POE
parameters, but nothing special is included.

=item ClientDisconnected

ClientDisconnected is a coderef that will be called for each client
that disconnects.  ClientDisconnected callbacks receive the usual POE
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
filter.  For example, this changes the line separator to a vertical
bar:

  ClientFilter => [ "POE::Filter::Line", Literal => "|" ],

ClientFilter is optional.  The component will supply a
"POE::Filter::Line" instance if none is specified.  If you supply a
different value for Filter, then you must also C<use> that filter
class.

=item ClientInputFilter

=item ClientOutputFilter

ClientInputFilter and ClientOutputFilter are provided to allow for
using different filters on the input from and output to each client.
Usage is the same as the ClientFilter option above, allowing either
a scalar or a list reference. Both must be defined in order to be
used, and these options override the ClientFilter option if its
defined as well.

Filter modules are required at runtime, and if either fails to be
loaded, it will fall back to the defaults as if no ClientFilter
option was defined.

  ClientInputFilter  => [ "POE::Filter::Line", Literal => "|" ],
  ClientOutputFilter => "POE::Filter::Stream",

=item ClientInput

ClientInput is a coderef that will be called to handle client input.
The callback receives its parameters directly from ReadWrite's
InputEvent.  ARG0 is the input record, and ARG1 is the wheel's unique
ID.

  ClientInput => \&input_handler

ClientInput and Acceptor are mutually exclusive.  Enabling one
prohibits the other.

=item ClientShutdownOnError => BOOLEAN

ClientShutdownOnError is a boolean value that determines whether
client sessions shut down automatically on errors.  The default value
is 1 (true).  Setting it to 0 or undef (false) turns this off.

If client shutdown-on-error is turned off, it becomes your
responsibility to deal with client errors properly.  Not handling
them, or not closing wheels when they should be, will cause the
component to spit out a constant stream of errors, eventually bogging
down your application with dead connections that spin out of control.

=item Domain

Specifies the domain within which communication will take place.  It
selects the protocol family which should be used.  Currently supported
values are AF_INET, AF_INET6, PF_INET or PF_INET6.  This parameter is
optional and will default to AF_INET if omitted.

Note: AF_INET6 and PF_INET6 are supplied by the Socket6 module, which
is available on the CPAN.  You must have Socket6 loaded before
POE::Component::Server::TCP will create IPv6 sockets.

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

=item Args LISTREF

Args passes the contents of a LISTREF to the ClientConnected callback via
@_[ARG0..$#_].  It allows you to pass extra information to the session
created to handle the client connection.

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
