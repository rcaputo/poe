# $Id$

# Select loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Loop::Select;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;
use Carp qw(confess);

# Delcare which event loop bridge is being used, but first ensure that
# no other bridge has been loaded.

BEGIN {
  die( "POE can't use its own loop and " . &POE_LOOP . "\n" )
    if defined &POE_LOOP;
};

sub POE_LOOP () { LOOP_SELECT }

# Linux has a bug on "polled" select() calls.  If select() is called
# with a zero-second timeout, and a signal manages to interrupt it
# anyway (it's happened), the select() function is restarted and will
# block indefinitely.  Set the minimum select() timeout to 1us on
# Linux systems.
BEGIN {
  my $timeout = ($^O eq 'linux') ? 0.001 : 0;
  eval "sub MINIMUM_SELECT_TIMEOUT () { $timeout }";
};

# select() vectors.  They're stored in an array so that the MODE_*
# offsets can refer to them.  This saves some code at the expense of
# clock cycles.
#
# [ $select_read_bit_vector,    (MODE_RD)
#   $select_write_bit_vector,   (MODE_WR)
#   $select_expedite_bit_vector (MODE_EX)
# ];
my @loop_vectors = ("", "", "");

# A record of the file descriptors we are actively watching.
my %loop_filenos;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  # Initialize the vectors as vectors.
  @loop_vectors = ( '', '', '' );
  vec($loop_vectors[MODE_RD], 0, 1) = 0;
  vec($loop_vectors[MODE_WR], 0, 1) = 0;
  vec($loop_vectors[MODE_EX], 0, 1) = 0;
}


sub loop_finalize {
  my $self = shift;

  # This is "clever" in that it relies on each symbol on the left to
  # be stringified by the => operator.
  my %kernel_modes =
    ( MODE_RD => MODE_RD,
      MODE_WR => MODE_WR,
      MODE_EX => MODE_EX,
    );

  while (my ($mode_name, $mode_offset) = each(%kernel_modes)) {
    my $bits = unpack('b*', $loop_vectors[$mode_offset]);
    if (index($bits, '1') >= 0) {
      warn "<rc> LOOP VECTOR LEAK: $mode_name = $bits\a\n";
    }
  }
}

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  if (TRACE_SIGNALS) {
    warn "<sg> Enqueuing generic SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue
    ( $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
      __FILE__, __LINE__, time()
    );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  if (TRACE_SIGNALS) {
    warn "<sg> Enqueuing PIPE-like SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue
    ( $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
      __FILE__, __LINE__, time()
    );
    $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _loop_signal_handler_child {
  if (TRACE_SIGNALS) {
    warn "<sg> Enqueuing CHLD-like SIG$_[0] event";
  }

  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_data_ev_enqueue
    ( $poe_kernel, $poe_kernel, EN_SCPOLL, ET_SCPOLL, [ ],
      __FILE__, __LINE__, time()
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my ($self, $signal) = @_;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $self->_data_ev_enqueue
      ( $self, $self, EN_SCPOLL, ET_SCPOLL, [ ],
        __FILE__, __LINE__, time() + 1
      ) if $signal eq 'CHLD' or not exists $SIG{CHLD};

    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_loop_signal_handler_pipe;
    return;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  return if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_loop_signal_handler_generic;
}

sub loop_ignore_signal {
  my ($self, $signal) = @_;
  $SIG{$signal} = "DEFAULT";
}

sub loop_attach_uidestroy {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  # does nothing ($_[0] == next time)
}

sub loop_reset_time_watcher {
  # does nothing ($_[0] == next time)
}

sub loop_pause_time_watcher {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 1;
  $loop_filenos{$fileno} |= (1<<$mode);
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 0;
  $loop_filenos{$fileno} &= ~(1<<$mode);
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 0;
  $loop_filenos{$fileno} &= ~(1<<$mode);
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 1;
  $loop_filenos{$fileno} |= (1<<$mode);
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  my $self = shift;

  # Check for a hung kernel.
  $self->_test_if_kernel_is_idle();

  # Set the select timeout based on current queue conditions.  If
  # there are FIFO events, then the timeout is zero to poll select and
  # move on.  Otherwise set the select timeout until the next pending
  # event, if there are any.  If nothing is waiting, set the timeout
  # for some constant number of seconds.

  my $now = time();
  my $timeout = $self->get_next_event_time();

  if (defined $timeout) {
    $timeout -= $now;
    $timeout = MINIMUM_SELECT_TIMEOUT if $timeout < MINIMUM_SELECT_TIMEOUT;
  }
  else {
    $timeout = 3600;
  }

  if (TRACE_EVENTS) {
    warn( '<ev> Kernel::run() iterating.  ' .
          sprintf("now(%.4f) timeout(%.4f) then(%.4f)\n",
                  $now-$^T, $timeout, ($now-$^T)+$timeout
                 )
        );
  }

  # Determine which files are being watched.
  my @filenos = ();
  while (my ($fd, $mask) = each(%loop_filenos)) {
    push(@filenos, $fd) if $mask;
  }

  if (TRACE_FILES) {
    warn( "<fh> ,----- SELECT BITS IN -----\n",
          "<fh> | READ    : ", unpack('b*', $loop_vectors[MODE_RD]), "\n",
          "<fh> | WRITE   : ", unpack('b*', $loop_vectors[MODE_WR]), "\n",
          "<fh> | EXPEDITE: ", unpack('b*', $loop_vectors[MODE_EX]), "\n",
          "<fh> `--------------------------\n"
        );
  }

  # Avoid looking at filehandles if we don't need to.  -><- The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if ($timeout or @filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = select( my $rout = $loop_vectors[MODE_RD],
                         my $wout = $loop_vectors[MODE_WR],
                         my $eout = $loop_vectors[MODE_EX],
                         $timeout,
                       );

      if (ASSERT_FILES) {
        if ($hits < 0) {
          confess "<fh> select error: $!"
            unless ( ($! == EINPROGRESS) or
                     ($! == EWOULDBLOCK) or
                     ($! == EINTR)
                   );
        }
      }

      if (TRACE_FILES) {
        if ($hits > 0) {
          warn "<fh> select hits = $hits\n";
        }
        elsif ($hits == 0) {
          warn "<fh> select timed out...\n";
        }
        warn( "<fh> ,----- SELECT BITS OUT -----\n",
              "<fh> | READ    : ", unpack('b*', $rout), "\n",
              "<fh> | WRITE   : ", unpack('b*', $wout), "\n",
              "<fh> | EXPEDITE: ", unpack('b*', $eout), "\n",
              "<fh> `---------------------------\n"
            );
      }

      # If select has seen filehandle activity, then gather up the
      # active filehandles and synchronously dispatch events to the
      # appropriate handlers.

      if ($hits > 0) {

        # This is where they're gathered.  It's a variant on a neat
        # hack Silmaril came up with.

        my (@rd_selects, @wr_selects, @ex_selects);
        foreach (@filenos) {
          push(@rd_selects, $_) if vec($rout, $_, 1);
          push(@wr_selects, $_) if vec($wout, $_, 1);
          push(@ex_selects, $_) if vec($eout, $_, 1);
        }

        if (TRACE_FILES) {
          if (@rd_selects) {
            warn( "<fh> found pending rd selects: ",
                  join( ', ', sort { $a <=> $b } @rd_selects ),
                  "\n"
                );
          }
          if (@wr_selects) {
            warn( "<sl> found pending wr selects: ",
                  join( ', ', sort { $a <=> $b } @wr_selects ),
                  "\n"
                );
          }
          if (@ex_selects) {
            warn( "<sl> found pending ex selects: ",
                  join( ', ', sort { $a <=> $b } @ex_selects ),
                  "\n"
                );
          }
        }

        if (ASSERT_FILES) {
          unless (@rd_selects or @wr_selects or @ex_selects) {
            confess "<fh> found no selects, with $hits hits from select???\n";
          }
        }

        # Enqueue the gathered selects, and flag them as temporarily
        # paused.  They'll resume after dispatch.

        @rd_selects and
          $self->_data_handle_enqueue_ready(MODE_RD, @rd_selects);
        @wr_selects and
          $self->_data_handle_enqueue_ready(MODE_WR, @wr_selects);
        @ex_selects and
          $self->_data_handle_enqueue_ready(MODE_EX, @ex_selects);
      }
    }

    # No filehandles to select on.  Four-argument select() fails on
    # MSWin32 with all undef bitmasks.  Use sleep() there instead.

    else {
      if ($^O eq 'MSWin32') {
        sleep($timeout);
      }
      else {
        select(undef, undef, undef, $timeout);
      }
    }
  }

  # Dispatch whatever events are due.
  $self->_data_ev_dispatch_due();
}

sub loop_run {
  my $self = shift;

  # Run for as long as there are sessions to service.
  while ($self->_data_ses_count()) {
    $self->loop_do_timeslice();
  }
}

sub loop_halt {
  # does nothing
}

1;

__END__

=head1 NAME

POE::Loop::Event - a bridge that supports select(2) from POE

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<select>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
