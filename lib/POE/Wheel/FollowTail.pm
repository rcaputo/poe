# $Id$
# Documentation exists after __END__

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $kernel = shift;
  my %params = @_;

  croak "Handle required" unless (exists $params{'Handle'});
  croak "Driver required" unless (exists $params{'Driver'});
  croak "Filter required" unless (exists $params{'Filter'});
  croak "InputState required" unless (exists $params{'InputState'});

  my ($handle, $driver, $filter, $state_in, $state_error) =
    @params{ qw(Handle Driver Filter InputState ErrorState) };

  my $self = bless { 'handle' => $handle,
                     'kernel' => $kernel,
                     'driver' => $driver,
                     'filter' => $filter,
                   }, $type;
                                        # pre-declare (whee!)
  $self->{'state read'} = $self . ' -> select read';
  $self->{'state wake'} = $self . ' -> alarm';
                                        # check for file activity
  $kernel->state
    ( $self->{'state read'},
      sub {
        my ($k, $me, $from, $handle) = @_;
        
        while (defined(my $raw_input = $driver->get($handle))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->post($me, $state_in, $cooked_input)
          }
        }

        $k->select_read($handle);

        if ($!) {
          $state_error && $k->post($me, $state_error, 'read', ($!+0), $!);
        }
        else {
          $k->alarm($self->{'state wake'}, time()+1);
        }
      }
    );
                                        # wake up and smell the filehandle
  $kernel->state
    ( $self->{'state wake'},
      sub {
        my ($k, $me) = @_;
        $k->select_read($handle, $self->{'state read'});
      }
    );
                                        # set the file position to the end
  seek($handle, 0, SEEK_END);
  seek($handle, -4096, SEEK_CUR);
                                        # discard partial lines and stuff
  while (defined(my $raw_input = $driver->get($handle))) {
    $filter->get($raw_input);
  }
                                        # nudge the wheel into action
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

  if ($self->{'state wake'}) {
    $self->{'kernel'}->state($self->{'state wake'});
    delete $self->{'state wake'};
  }
}

###############################################################################
1;
__END__

=head1 NAME

POE::Wheel::FollowTail - follow the end of a file, notifying a session
whenever a complete unit of information appears

=head1 SYNOPSIS

  $wheel_rw = new POE::Wheel::FollowTail
    ( $kernel,
      'Handle' => $handle,
      'Driver' => new POE::Driver::SysRW,  # or another POE::Driver
      'Filter' => new POE::Filter::Line,   # or another POE::Filter
      'InputState'   => $input_state_name, # accepts filtered-input events
      'ErrorState'   => $error_state_name, # accepts error states
    );

=head1 DESCRIPTION

C<POE::Wheel::FollowTail> works much like C<POE::Wheel::ReadWrite> except that
FollowTail is a read-only wheel (no 'FlushedState') and it starts from the
end of a file.

Every complete chunk of input is passed back to the parent C<POE::Session>
as a parameter of an 'InputState' event.

If an error occurs, its number and text are sent to the 'ErrorState'.  If
no 'ErrorState' is provided, the FollowTail wheel will turn off selects for
C<$handle> to prevent extra events from being generated.  This may stop the
the parent C<POE::Session> if the selects are all it is waiting for.

=head1 PUBLIC METHODS

=over 4

=item new POE::Wheel::FollowTail

Creates a FollowTail wheel.  C<$kernel> is the kernel that owns the currently
running session (the session that creates this wheel).

Parameters specific to FollowTail:

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

=item 'ErrorState'

This names the event that will receive notification of any errors that occur
when 'Driver' is reading or writing.

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

Removes C<POE::Wheel::FollowTail> states from the parent C<POE::Session>.
Releases owned objects so Perl can GC them.

=back

=head1 EXAMPLES

Please see tests/followtail.perl for an example of C<POE::Wheel::FollowTail>.

=head1 BUGS

Possible enhancement: Automagically reset the file position when a log
shrinks, so whatever is watching it does not need to be restarted.

'Position' constructor parameter, so the "current" file position can be
maintained between runs.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
