# $Id$
# Documentation exists after __END__

package POE::Wheel::ListenAccept;

use strict;
use Carp;
use POSIX qw(EAGAIN);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $kernel = shift;
  my %params = @_;

  croak "Handle required" unless (exists $params{'Handle'});
  croak "AcceptState required" unless (exists $params{'AcceptState'});

  my ($handle, $state_accept, $state_error) =
    @params{ qw(Handle AcceptState ErrorState) };

  my $self = bless { 'handle' => $handle,
                     'kernel' => $kernel,
                   }, $type;
                                        # register the select-read handler
  $kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
        my ($k, $me, $from, $handle) = @_;

        my $new_socket = $handle->accept();

        if ($new_socket) {
          $k->post($me, $state_accept, $new_socket);
        }
        elsif ($! != EAGAIN) {
          $state_error && $k->post($me, $state_error, 'accept', ($!+0), $!);
        }
      }
    );

  $kernel->select($handle, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $self->{'kernel'}->select($self->{'handle'});

  if ($self->{'state read'}) {
    $self->{'kernel'}->state($self->{'state read'});
    delete $self->{'state read'};
  }
}

###############################################################################
1;
__END__

=head1 NAME

POE::Wheel::ListenAccept - accept connections for a listening C<IO::Socket>

=head1 SYNOPSIS

  $wheel_rw = new POE::Wheel::ReadWrite
    ( $kernel,
      'Handle' => $handle,
      'AcceptState' => $accept_state_name, # accepts accepted sockets
      'ErrorState'  => $error_state_name,  # accepts error states
    );

=head1 DESCRIPTION

C<POE::Wheel::ListenAccept> manages a listening C<IO::Socket> and accepts new
connections.  Successfully connections are passed to 'AcceptState' for custom
processing (for example, creating a new C<POE::Session> to interact with the
socket).

=head1 PUBLIC METHODS

=over 4

=item new POE::Wheel::ListenAccept

Creates a ListenAccept wheel.  C<$kernel> is the kernel that owns the currently
running session (the session that creates this wheel).

Parameters specific to ListenAccept:

=over 0

=item 'Handle'

This is the filehandle that currently is listening for connections.

=item 'AcceptState'

This names the event that will be sent to the current session whenever a
connection is accepted.

'InputState' handlers will receive these parameters: C<$kernel>, C<$namespace>,
C<$origin_session>, C<$new_socket>.  The first three are standard; the last
is a filehandle for the socket created by C<accept()>.

=item 'ErrorState'

This names the event that will receive notification of any errors that occur
while trying to accept a connection.

'ErrorState' handlers will these parameters: C<$kernel>, C<$namespace>,
C<$origin_session>, C<$operation>, C<$errnum>, C<$errstr>.  The first three are
standard; C<$operation> is either 'read' or 'write'; C<$errnum> is C<($!+0)>;
C<$errstr> is C<$!>.

=back

=back

=head1 PRIVATE METHODS

Not for general use.

=over 4

=item DESTROY

Removes C<POE::Wheel::ListenAccept> states from the parent C<POE::Session>.

=back

=head1 EXAMPLES

Please see tests/wheels.perl for an example of C<POE::Wheel::ListenAccept>.
Also see tests/selects.perl to see the non-wheel way to do things.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
