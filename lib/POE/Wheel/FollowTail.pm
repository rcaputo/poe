# $Id$

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my %params = @_;

  croak "wheels no longer require a kernel reference as their first parameter"
    if (@_ && (ref($_[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel"
    unless (defined $poe_kernel);

  croak "Handle required"     unless (exists $params{'Handle'});
  croak "Driver required"     unless (exists $params{'Driver'});
  croak "Filter required"     unless (exists $params{'Filter'});
  croak "InputState required" unless (exists $params{'InputState'});

  my ($handle, $driver, $filter, $state_in, $state_error) =
    @params{ qw(Handle Driver Filter InputState ErrorState) };

  my $poll_interval = ( (exists $params{'PollInterval'})
                        ? $params{'PollInterval'}
                        : 1
                      );

  my $self = bless { 'handle'   => $handle,
                     'driver'   => $driver,
                     'filter'   => $filter,
                     'interval' => $poll_interval,
                     'event input' => $params{'InputState'},
                     'event error' => $params{'ErrorEvent'},
                   }, $type;
                                        # register the input state
  $poe_kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $ses, $hdl) = @_[KERNEL, SESSION, ARG0];

        while (defined(my $raw_input = $driver->get($hdl))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->call($ses, $self->{'event input'}, $cooked_input)
          }
        }

        $k->select_read($hdl);

        if ($!) {
          defined($self->{'event error'})
            && $k->call($ses, $self->{'event error'}, 'read', ($!+0), $!);
        }
        else {
          $k->delay($self->{'state wake'}, $poll_interval);
        }
      }
    );
                                        # set the file position to the end
  seek($handle, 0, SEEK_END);
  seek($handle, -4096, SEEK_CUR);
                                        # discard partial input chunks
  while (defined(my $raw_input = $driver->get($handle))) {
    $filter->get($raw_input);
  }
                                        # register the alarm state
  $poe_kernel->state
    ( $self->{'state wake'} = $self . ' -> alarm',
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my $k = $_[KERNEL];
        $k->select_read($handle, $self->{'state read'});
      }
    );
                                        # nudge the wheel into action
  $poe_kernel->select($handle, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'InputState') {
      if (defined $event) {
        $self->{'event input'} = $event;
      }
      else {
        carp "InputState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->{'event error'} = $event;
    }
    else {
      carp "ignoring unknown ReadWrite parameter '$name'";
    }
  }
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->{'handle'});

  if ($self->{'state read'}) {
    $poe_kernel->state($self->{'state read'});
    delete $self->{'state read'};
  }

  if ($self->{'state wake'}) {
    $poe_kernel->state($self->{'state wake'});
    delete $self->{'state wake'};
  }
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel - POE FollowTail Protocol Logic

=head1 SYNOPSIS

  $wheel = new POE::Wheel::FollowTail(
    Handle       => $file_handle,                 # File to tail
    Driver       => new POE::Driver::Something(), # How to read it
    Filter       => new POE::Filter::Something(), # How to parse it
    PollInterval => 1,                  # How often to check it
    InputState   => $input_event_name,  # State to call upon input
    ErrorState   => $error_event_name,  # State to call upon error
  );

=head1 DESCRIPTION

This wheel follows the end of an ever-growing file, perhaps a log
file, and generates events whenever new data appears.  It is a
read-only wheel, so it does not include a put() method.  It uses
tell() and seek() functions, so it's only suitable for plain files.
It won't tail pipes or consoles.

=head1 PUBLIC METHODS

=over 4

=item *

POE::Wheel::FollowTail::event(...)

Please see POE::Wheel.

=back

=head1 EVENTS AND PARAMETERS

=over 4

=item *

PollInterval

PollInterval is the number of seconds to wait between file checks.
Once FollowTail re-reaches the end of the file, it waits this long
before checking again.

=item *

InputState

The InputState event is identical to POE::Wheel::ReadWrite's
InputState.  It's the state to be called when the followed file
lengthens.

ARG0 contains a logical chunk of data, read from the end of the tailed
file.

=item *

ErrorState

The ErrorState event contains the name of the state that will be
called when a file error occurs.  The FollowTail wheel knows what to
do with EAGAIN, so it's not considered a true error.

The ARG0 parameter contains the name of the function that failed.
ARG1 and ARG2 contain the numeric and string versions of $! at the
time of the error, respectively.

A sample ErrorState state:

  sub error_state {
    my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
    warn "$operation error $errnum: $errstr\n";
  }

=back

=head1 SEE ALSO

POE::Wheel; POE::Wheel::ListenAccept; POE::Wheel::ReadWrite;
POE::Wheel::SocketFactory

=head1 BUGS

This wheel can't tail pipes and consoles.  Blargh.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
