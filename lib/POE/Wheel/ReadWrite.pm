# $Id$
# Documentation exists after __END__

package POE::Wheel::ReadWrite;

use strict;
use Carp;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $kernel = shift;
  my %params = @_;

  croak "Handle required" unless (exists $params{'Handle'});
  croak "Driver required" unless (exists $params{'Driver'});
  croak "Filter required" unless (exists $params{'Filter'});
  croak "InputState required" unless (exists $params{'InputState'});

  my ($handle, $driver, $filter, $state_in, $state_flushed, $state_error) =
    @params{ qw(Handle Driver Filter InputState FlushedState ErrorState) };

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
          $state_error && $k->post($me, $state_error, 'read', ($!+0), $!);
          $k->select_read($handle);
        }
      }
    );
                                        # register the select-write handler
  $kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {
        my ($k, $me, $from, $handle) = @_;

        my $writes_pending = $driver->flush($handle);
        if (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
          }
        }
        elsif ($!) {
          $state_error && $k->post($me, $state_error, 'write', ($!+0), $!);
          $k->select_write($handle);
        }
        elsif ($state_flushed) {
          $k->post($me, $state_flushed);
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

POE::Wheel::ReadWrite - glue to connect C<select(2)>, a C<POE::Driver>, a C<POE::Filter> and the current C<POE::Session>

=head1 SYNOPSIS

  $wheel_rw = new POE::Wheel::ReadWrite
    ( $kernel,
      'Handle' => $handle,
      'Driver' => new POE::Driver::SysRW,  # or another POE::Driver
      'Filter' => new POE::Filter::Line,   # or another POE::Filter
      'InputState'   => $input_state_name, # accepts filtered-input events
      'FlushedState' => $flush_state_name, # accepts output-flushed events
      'ErrorState'   => $error_state_name, # accepts error states
    );

=head1 DESCRIPTION

C<POE::Wheel::ReadWrite> adds C<select(2)> states to the current
C<POE::Session>.  These states invoke the associated C<POE::Driver> to frob
C<$handle>, then pass the stream info to C<POE::Filter> for formatting.  The
example in the SYNOPSIS above implements line-based IO.

Every complete chunk of input is passed back to the parent C<POE::Session>
as a parameter of an 'InputState' event.

The ReadWrite wheel sends 'FlushedState' events whenever its C<POE::Driver>
has written all the pending data to C<$handle>.  This is optional.

If an error occurs, its number and text are sent to the 'ErrorState'.  If
no 'ErrorState' is provided, the ReadWrite wheel will turn off selects for
C<$handle> to prevent extra events from being generated.  This may stop the
the parent C<POE::Session> if the selects are all it is waiting for.

=head1 PUBLIC METHODS

=over 4

=item new POE::Wheel::ReadWrite

Creates a ReadWrite wheel.  C<$kernel> is the kernel that owns the currently
running session (the session that creates this wheel).

Parameters specific to ReadWrite:

=over 0

=item 'Handle'

This is the C<IO::Handle> derivative that will be read from and written to.

=item 'Driver'

This is the C<POE::Driver> derivative that will do the actual reading and
writing.

=item 'Filter'

This is the C<POE::Filter> derivative that will frame input and output for the
current C<POE::Session>.

=item 'InputState'

This names the event that will be sent to the current session whenever a
fully-framed chunk of data has been read from the 'Handle'.

'InputState' handlers will receive these parameters: C<$kernel>, C<$namespace>,
C<$origin_session>, C<$cooked_input>.  The first three are standard; the last
is a post-C<POE::Filter> chunk of input.

=item 'FlushedState'

This names the event that will be sent to the current session whenever all
buffered output has been written to 'Handle'.

'FlushedState' handlers will receive these parameters: C<$kernel>,
C<$namespace>, C<$origin_session>.  See _start for C<POE::Session> for an
explication.

=item 'ErrorState'

This names the event that will receive notification of any errors that occur
when 'Driver' is reading or writing.

'ErrorState' handlers will these parameters: C<$kernel>, C<$namespace>,
C<$origin_session>, C<$operation>, C<$errnum>, C<$errstr>.  The first three are
standard; C<$operation> is either 'read' or 'write'; C<$errnum> is C<($!+0)>;
C<$errstr> is C<$!>.

=back

=item put ($output)

Have the wheel send a chunk of output.

C<POE::Wheel::ReadWrite> formats C<$output> using its C<POE::Filter>.  The
formatted output is buffered for writing by the C<POE::Driver>.  The ReadWrite
wheel then uses C<$kernel->select(...)> to enable a write state that will flush
the output buffer.

C<POE::Wheel::ReadWrite> sends a 'FlushedState' event to the session when all
buffered output has been written, and it calls C<$kernel->select(...)> to
disable the previously selected write state.

If any errors occur during reading or writing, they are passed back to the
parent C<POE::Session> as an 'ErrorState' event.

=back

=head1 PRIVATE METHODS

Not for general use.

=over 4

=item DESTROY

Removes C<POE::Wheel::ReadWrite> states from the parent C<POE::Session>.
Releases owned objects so Perl can GC them.

=back

=head1 EXAMPLES

Please see tests/wheels.perl for an example of C<POE::Wheel::ReadWrite>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
