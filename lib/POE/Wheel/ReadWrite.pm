package POE::Wheel::ReadWrite;

# POD documentation exists after __END__
# '$Id$';

my $VERSION = 1.0;

use strict;

#------------------------------------------------------------------------------

sub new {
  my ($type, $kernel, $handle, $driver, $filter, $state_in, $state_flush,
      $state_error
     ) = @_;
  my $self = bless { 'handle' => $handle,
                     'kernel' => $kernel,
                     'driver' => $driver,
                     'filter' => $filter,
                   }, $type;
                                        # register the select-read handler
  $kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
        my ($k, $me, $from, $handle) = @_;
        if (defined(my $raw_input = $driver->get($handle))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->post($me, $state_in, $cooked_input)
          }
        }
        else {
          $k->post($me, $state_error, 'read', $!);
          $k->select_read($handle);
        }
      }
    );
                                        # register the select-write handler
  $kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {
        my ($k, $me, $from, $handle) = @_;

        my $writes_pending = $driver->flush($k, $handle);
        if (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
          }
        }
        elsif ($!) {
          $k->post($me, $state_error, 'write', $!);
          $k->select_write($handle);
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

  if ($self->{'state write'}) {
    $self->{'kernel'}->state($self->{'state write'});
    delete $self->{'state write'};
  }
}

#------------------------------------------------------------------------------

sub put {
  my $self = shift;
  if ($self->{'driver'}->put($self->{'filter'}->put(join('', @_)))) {
    $self->{'kernel'}->select_write($self->{'handle'}, $self->{'state write'});
  }
}

###############################################################################
1;
__END__

=head1 NAME

POE::Wheel::ReadWrite - manage read/write states for a session

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 PUBLIC METHODS

=over 4

=item new POE::Wheel::ReadWrite

=over 2

=item Takes:
=item C<$kernel> - A C<POE::Kernel> instance.
=item C<$handle> - A reference to an object based on C<IO::Handle>.
=item C<'driver' =E<gt> $driver> - A C<POE::Driver::*> reference.
=item C<'filter' =E<gt> $filter> - A C<POE::Filter::*> reference.
=item C<'input state' =E<gt> $state_name> - the C<POE::Session> state that will accept filtered input.
=item C<'flushed state' =E<gt> $state_name> - Optional.  The C<POE::Session> state that needs to know when all C<$handle> output is flushed.

($kernel, $handle,$driver, $filter, $state_in, $state_flush, $state_error)

=item put($unit_of_output)

=back

=head1 PROTECTED METHODS

None.

=head1 PRIVATE METHODS

Not for general use.

=over 4

=item DESTROY

Actually does something.  Document, please.

=head1 EXAMPLES

Please see the tests directory that comes with the POE bundle.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
