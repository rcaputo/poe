# $Id$

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);
use POE;

sub CRIMSON_SCOPE_HACK ($) { 0 }

# Turn on tracing.  A lot of debugging occurred just after 0.11.
sub TRACE () { 0 }

# Tk doesn't provide a SEEK method, as of 800.022
BEGIN {
  if (exists $INC{'Tk.pm'}) {
    eval <<'    EOE';
      sub Tk::Event::IO::SEEK {
        my $o = shift;
        $o->wait(Tk::Event::IO::READABLE);
        my $h = $o->handle;
        sysseek($h, shift, shift);
      }
    EOE
  }
}

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

  my ($handle, $driver, $filter) = @params{ qw(Handle Driver Filter) };

  my $poll_interval = ( (exists $params{'PollInterval'})
                        ? $params{'PollInterval'}
                        : 1
                      );

  my $seek_back = ( ( exists($params{SeekBack})
                      and defined($params{SeekBack})
                    )
                    ? $params{SeekBack}
                    : 4096
                  );
  $seek_back = 0 if $seek_back < 0;

  my $self = bless { handle      => $handle,
                     driver      => $driver,
                     filter      => $filter,
                     interval    => $poll_interval,
                     event_input => $params{'InputState'},
                     event_error => $params{'ErrorEvent'},
                   }, $type;

  $self->_define_states();

  # Nudge the wheel into action before performing initial operations
  # on it.  Part of the Kernel's select() logic is making things
  # non-blocking, and the following code will assume that.

  $poe_kernel->select($handle, $self->{state_read});

  # Try to position the file pointer before the end of the file.  This
  # is so we can "tail -f" an existing file.  FreeBSD, at least,
  # allows sysseek to go before the beginning of a file.  Trouble
  # ensues at that point, causing the file never to be read again.
  # This code does some extra work to prevent seeking beyond the start
  # of a file.

  eval {
    my $end = sysseek($handle, 0, SEEK_END);
    if (defined($end) and ($end < $seek_back)) {
      sysseek($handle, 0, SEEK_SET);
    }
    else {
      sysseek($handle, -$seek_back, SEEK_END);
    }
  };

  # Discard partial input chunks unless a SeekBack was specified.
  unless (exists $params{SeekBack}) {
    while (defined(my $raw_input = $driver->get($handle))) {
      # Skip out if there's no more input.
      last unless @$raw_input;
      $filter->get($raw_input);
    }
  }

  $self;
}

#------------------------------------------------------------------------------
# This relies on stupid closure tricks to keep references to $self out
# of anonymous coderefs.  Otherwise, the wheel won't disappear when a
# state deletes it.

sub _define_states {
  my $self = shift;

  # If any of these change, then the states are invalidated and must
  # be redefined.

  my $filter        = $self->{filter};
  my $driver        = $self->{driver};
  my $event_input   = \$self->{event_input};
  my $event_error   = \$self->{event_error};
  my $state_wake    = $self->{state_wake} = $self . ' alarm';
  my $state_read    = $self->{state_read} = $self . ' select read';
  my $poll_interval = $self->{interval};
  my $handle        = $self->{handle};

  # Define the read state.

  TRACE and do { warn $state_read; };

  $poe_kernel->state
    ( $state_read,
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my ($k, $ses, $hdl) = @_[KERNEL, SESSION, ARG0];

        $k->select_read($hdl);

        eval { sysseek($hdl, 0, SEEK_CUR); };
        $! = 0;

        TRACE and do { warn time . " read ok\n"; };

        if (defined(my $raw_input = $driver->get($hdl))) {
          TRACE and do { warn time . " raw input\n"; };
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            TRACE and do { warn time . " cooked input\n"; };
            $k->call($ses, $$event_input, $cooked_input);
          }
        }

        if ($!) {
          TRACE and do { warn time . " error: $!\n"; };
          $$event_error && $k->call($ses, $$event_error, 'read', ($!+0), $!);
        }

        TRACE and do { warn time . " set delay\n"; };
        $k->delay($state_wake, $poll_interval);
      }
    );

  # Define the alarm state that periodically wakes the wheel and
  # retries to read from the file.

  TRACE and do { warn $state_wake; };

  $poe_kernel->state
    ( $state_wake,
      sub {
                                        # prevents SEGV
        0 && CRIMSON_SCOPE_HACK('<');
                                        # subroutine starts here
        my $k = $_[KERNEL];

        TRACE and do { warn time . " wake up and select the handle\n"; };

        $k->select_read($handle, $state_read);
      }
    );
}

#------------------------------------------------------------------------------

sub event {
  my $self = shift;
  push(@_, undef) if (scalar(@_) & 1);

  while (@_) {
    my ($name, $event) = splice(@_, 0, 2);

    if ($name eq 'InputState') {
      if (defined $event) {
        $self->{event_input} = $event;
      }
      else {
        carp "InputState requires an event name.  ignoring undef";
      }
    }
    elsif ($name eq 'ErrorState') {
      $self->{event_error} = $event;
    }
    else {
      carp "ignoring unknown FollowTail parameter '$name'";
    }
  }

  $self->_define_states();
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $poe_kernel->select($self->{handle});

  if ($self->{state_read}) {
    $poe_kernel->state($self->{state_read});
    delete $self->{state_read};
  }

  if ($self->{state_wake}) {
    $poe_kernel->state($self->{state_wake});
    delete $self->{state_wake};
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
sysseek(2) wrapped in eval { }, so it should work okay on all sorts of
files.  That is, if perl supports select(2)'ing them on the underlying
operating system.

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

SeekBack

SeekBack is the number of bytes to seek back from the current end of
file before reading.  By default, this is 4096, and data read up to
the end of file is not returned.  (This is used to frame lines before
returning actual data.)  If SeekBack is specified, then existing data
up until EOF is returned, and then the wheel begins following tail.

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
do with EAGAIN, so it's not considered a true error.  FollowTail will
continue running even on an error, so it's up to the Session to stop
things if that's what it wants.

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
