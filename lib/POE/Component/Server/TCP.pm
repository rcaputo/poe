# $Id$

package POE::Component::Server::TCP;

use strict;

use Carp qw(carp croak);
use vars qw($VERSION);

$VERSION = 1.00;

# Explicit use to import the parameter constants.
use POE::Session;
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
  croak "$mi needs an Acceptor parameter" unless exists $param{Acceptor};

  # Extract parameters.
  my $port = delete $param{Port};
  my $accept_callback = delete $param{Acceptor};
  my $error_callback = delete $param{Error};

  # Complain about strange things we're given.
  foreach (sort keys %param) {
    carp "$mi doesn't recognize \"$_\" as a parameter";
  }

  # Create the session, at long last.

  POE::Session->new

    # The POE::Session has been set up.  Create a listening socket
    # factory which will call back $callback with accepted client
    # sockets.
    ( _start =>
      sub {
        $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new
          ( BindPort     => $port,
            Reuse        => 'yes',
            SuccessState => 'got_connection',
            FailureState => 'got_error',
          );
      },

      # Catch an error.
      got_error => ( defined($error_callback)
                     ? $error_callback
                     : \&default_error_handler
                   ),

      # We accepted a connection.  Do something with it.
      got_connection => $accept_callback,
    );

  # Return undef so nobody can use the POE::Session reference.  This
  # isn't very friendly, but it saves grief later.
  undef;
}

# The default error handler logs to STDERR and shuts down the server.
sub default_error_handler {
  warn( 'Server ', $_[SESSION]->ID,
        " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
      );
  delete $_[HEAP]->{listener};
}

1;

__END__

=head1 NAME

POE::Component::Server::TCP - a simplified TCP server

=head1 SYNOPSIS

  use POE;

  sub accept_handler {
    my ($socket, $remote_address, $remote_port) = @_[ARG0, ARG1, ARG2];
    # code goes here to handle the accepted socket
  }

  sub error_handler {
    my ($op, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
    warn "server encountered $op error $errnum: $errstr";
    # possibly shut down the server
  }

  POE::Component::Server::TCP->new
    ( Port     => $bind_port,
      Acceptor => \&accept_handler,
      Error    => \&error_handler,  # Optional.
    );

=head1 DESCRIPTION

The TCP server component hides the steps needed to create a server
using Wheel::SocketFactory.  The steps aren't many, but they're still
repetitive and thus boring.

POE::Component::Server::TCP helps out by supplying a default error
handler.  This handler will write an error message on STDERR and shut
the server down.

The TCP server component takes three named arguments.  It's expected
to accept other parameters as it evolves.

=over 2

=item Port

Port is the port the listening socket will be bound to.

  Port => 30023

=item Acceptor

Acceptor is a coderef which will be called to handle accepted sockets.
The coderef is used as POE::Wheel::SocketFactory's SuccessState, so it
accepts the same parameters.

  Acceptor => \&success_state

=item Error

Error is an optional coderef which will be called to handle server
socket errors.  The coderef is used as POE::Wheel::SocketFactory's
FailureState, so it accepts the same parameters.  If it is omitted, a
default error handler will be provided.  The default handler will log
the error to STDERR and shut down the server.

=back

=head1 SEE ALSO

POE::Wheel::SocketFactory

=head1 BUGS

POE::Component::Server::TCP currently does not accept many of the
options that POE::Wheel::SocketFactory does, but it can be expanded
easily to do so.

=head1 AUTHORS & COPYRIGHTS

POE::Component::Server::TCP is Copyright 2000 by Rocco Caputo.  All
rights are reserved.  POE::Component::Server::TCP is free software,
and it may be redistributed and/or modified under the same terms as
Perl itself.

=cut
