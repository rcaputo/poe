# $Id$

# Select loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Select;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

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

# select() vectors.  They're stored in an array so that the VEC_RD,
# VEC_WR, and VEC_EX offsets work.  This saves some code, but it makes
# things a little slower.
#
# [ $select_read_bit_vector,    (VEC_RD)
#   $select_write_bit_vector,   (VEC_WR)
#   $select_expedite_bit_vector (VEC_EX)
# ];
my @loop_vectors = ("", "", "");

# A record of the file descriptors we are actively watching.
my %loop_filenos;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $kernel = shift;

  # Initialize the vectors as vectors.
  @loop_vectors = ( '', '', '' );
  vec($loop_vectors[VEC_RD], 0, 1) = 0;
  vec($loop_vectors[VEC_WR], 0, 1) = 0;
  vec($loop_vectors[VEC_EX], 0, 1) = 0;
}


sub loop_finalize {
  # This is "clever" in that it relies on each symbol on the left to
  # be stringified by the => operator.
  my %kernel_vectors =
    ( VEC_RD => VEC_RD,
      VEC_WR => VEC_WR,
      VEC_EX => VEC_EX,
    );

  while (my ($vec_name, $vec_offset) = each(%kernel_vectors)) {
    my $bits = unpack('b*', $loop_vectors[$vec_offset]);
    if (index($bits, '1') >= 0) {
      warn "*** LOOP VECTOR LEAK: $vec_name = $bits\a\n";
    }
  }
}

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( time(), $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
      __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( time(), $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
      __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _loop_signal_handler_child {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_event
    ( time(), $poe_kernel, $poe_kernel, EN_SCPOLL, ET_SCPOLL, [ ],
      __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my $signal = shift;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $poe_kernel->_enqueue_event
      ( time() + 1, $poe_kernel, $poe_kernel, EN_SCPOLL, ET_SCPOLL, [ ],
        __FILE__, __LINE__
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
  my $signal = shift;
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
  # does nothing ($_[0] == next time)
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($handle, $vector) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$vector], $fileno, 1) = 1;
  $loop_filenos{$fileno} |= (1<<$vector);
}

sub loop_ignore_filehandle {
  my ($handle, $vector) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$vector], $fileno, 1) = 0;
  $loop_filenos{$fileno} &= ~(1<<$vector);
}

sub loop_pause_filehandle_watcher {
  my ($handle, $vector) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$vector], $fileno, 1) = 0;
  $loop_filenos{$fileno} &= ~(1<<$vector);
}

sub loop_resume_filehandle_watcher {
  my ($handle, $vector) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$vector], $fileno, 1) = 1;
  $loop_filenos{$fileno} |= (1<<$vector);
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  # Check for a hung kernel.
  _data_test_for_idle_poe_kernel();

  # Set the select timeout based on current queue conditions.  If
  # there are FIFO events, then the timeout is zero to poll select and
  # move on.  Otherwise set the select timeout until the next pending
  # event, if there are any.  If nothing is waiting, set the timeout
  # for some constant number of seconds.

  my $now = time();
  my $timeout = $poe_kernel->get_next_event_time();

  if (defined $timeout) {
    $timeout -= $now;
    $timeout = MINIMUM_SELECT_TIMEOUT if $timeout < MINIMUM_SELECT_TIMEOUT;
  }
  else {
    $timeout = 3600;
  }

  if (TRACE_QUEUE) {
    warn( '*** Kernel::run() iterating.  ' .
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

  if (TRACE_SELECT) {
    warn ",----- SELECT BITS IN -----\n";
    warn "| READ    : ", unpack('b*', $loop_vectors[VEC_RD]), "\n";
    warn "| WRITE   : ", unpack('b*', $loop_vectors[VEC_WR]), "\n";
    warn "| EXPEDITE: ", unpack('b*', $loop_vectors[VEC_EX]), "\n";
    warn "`--------------------------\n";
  }

  # Avoid looking at filehandles if we don't need to.  -><- The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if ($timeout or @filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = select( my $rout = $loop_vectors[VEC_RD],
                         my $wout = $loop_vectors[VEC_WR],
                         my $eout = $loop_vectors[VEC_EX],
                         $timeout,
                       );

      if (ASSERT_SELECT) {
        if ($hits < 0) {
          confess "select error: $!"
            unless ( ($! == EINPROGRESS) or
                     ($! == EWOULDBLOCK) or
                     ($! == EINTR)
                   );
        }
      }

      if (TRACE_SELECT) {
        if ($hits > 0) {
          warn "select hits = $hits\n";
        }
        elsif ($hits == 0) {
          warn "select timed out...\n";
        }
        warn ",----- SELECT BITS OUT -----\n";
        warn "| READ    : ", unpack('b*', $rout), "\n";
        warn "| WRITE   : ", unpack('b*', $wout), "\n";
        warn "| EXPEDITE: ", unpack('b*', $eout), "\n";
        warn "`---------------------------\n";
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

        if (TRACE_SELECT) {
          if (@rd_selects) {
            warn( "found pending rd selects: ",
                  join( ', ', sort { $a <=> $b } @rd_selects ),
                  "\n"
                );
          }
          if (@wr_selects) {
            warn( "found pending wr selects: ",
                  join( ', ', sort { $a <=> $b } @wr_selects ),
                  "\n"
                );
          }
          if (@ex_selects) {
            warn( "found pending ex selects: ",
                  join( ', ', sort { $a <=> $b } @ex_selects ),
                  "\n"
                );
          }
        }

        if (ASSERT_SELECT) {
          unless (@rd_selects or @wr_selects or @ex_selects) {
            die "found no selects, with $hits hits from select???\a\n";
          }
        }

        # Enqueue the gathered selects, and flag them as temporarily
        # paused.  They'll resume after dispatch.

        @rd_selects and _data_enqueue_ready_selects(VEC_RD, @rd_selects);
        @wr_selects and _data_enqueue_ready_selects(VEC_WR, @wr_selects);
        @ex_selects and _data_enqueue_ready_selects(VEC_EX, @ex_selects);
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
  _data_dispatch_due_events();
}

sub loop_run {
  # Run for as long as there are sessions to service.
  while ($poe_kernel->get_session_count()) {
    loop_do_timeslice();
  }
}

sub loop_halt {
  # does nothing
}

1;
