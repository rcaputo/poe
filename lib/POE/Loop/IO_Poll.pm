# $Id$

# IO::Poll event loop bridge for POE::Kernel.  The theory is that this
# will be faster for large scale applications.  This file is
# contributed by Matt Sergeant (baud).

# Empty package to appease perl.
package POE::Loop::Poll;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

# Include common signal handling.
use POE::Loop::PerlSignals;

# Everything plugs into POE::Kernel;
package POE::Kernel;

use strict;

# Delcare which event loop bridge is being used, but first ensure that
# no other bridge has been loaded.

BEGIN {
  die "POE can't use IO::Poll and " . &POE_LOOP . "\n"
    if defined &POE_LOOP;
  die "IO::Poll is version $IO::Poll::VERSION (POE needs 0.05 or newer)\n"
    if $IO::Poll::VERSION < 0.05;
};

sub POE_LOOP () { LOOP_POLL }

use IO::Poll qw( POLLRDNORM POLLWRNORM POLLRDBAND
                 POLLIN POLLOUT POLLERR POLLHUP
               );

sub MINIMUM_POLL_TIMEOUT () { 0 }

my %poll_fd_masks;

# Allow $^T to change without affecting our internals.
my $start_time = $^T;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;
  %poll_fd_masks = ();
}

sub loop_finalize {
  # does nothing
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_attach_uidestroy {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  # does nothing
}

sub loop_reset_time_watcher {
  # does nothing
}

sub loop_pause_time_watcher {
  # does nothing
}

# A static function; not some object method.

sub mode_to_poll {
  return POLLIN     if $_[0] == MODE_RD;
  return POLLOUT    if $_[0] == MODE_WR;
  return POLLRDBAND if $_[0] == MODE_EX;
  croak "unknown I/O mode $_[0]";
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  my $type = mode_to_poll($mode);
  my $current = $poll_fd_masks{$fileno} || 0;
  my $new = $current | $type;

  if (TRACE_FILES) {
    POE::Kernel::_warn(
      sprintf(
        "<fh> Watch $fileno: " .
        "Current mask: 0x%02X - including 0x%02X = 0x%02X\n",
        $current, $type, $new
      )
    );
  }

  $poll_fd_masks{$fileno} = $new;
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  my $type = mode_to_poll($mode);
  my $current = $poll_fd_masks{$fileno} || 0;
  my $new = $current & ~$type;

  if (TRACE_FILES) {
    POE::Kernel::_warn(
      sprintf(
        "<fh> Ignore $fileno: " .
        ": Current mask: 0x%02X - removing 0x%02X = 0x%02X\n",
        $current, $type, $new
      )
    );
  }

  if ($new) {
    $poll_fd_masks{$fileno} = $new;
  }
  else {
    delete $poll_fd_masks{$fileno};
  }
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  my $type = mode_to_poll($mode);
  my $current = $poll_fd_masks{$fileno} || 0;
  my $new = $current & ~$type;

  if (TRACE_FILES) {
    POE::Kernel::_warn(
      sprintf(
        "<fh> Pause $fileno: " .
        ": Current mask: 0x%02X - removing 0x%02X = 0x%02X\n",
        $current, $type, $new
      )
    );
  }

  if ($new) {
    $poll_fd_masks{$fileno} = $new;
  }
  else {
    delete $poll_fd_masks{$fileno};
  }
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  my $type = mode_to_poll($mode);
  my $current = $poll_fd_masks{$fileno} || 0;
  my $new = $current | $type;

  if (TRACE_FILES) {
    POE::Kernel::_warn(
      sprintf(
        "<fh> Resume $fileno: " .
        "Current mask: 0x%02X - including 0x%02X = 0x%02X\n",
        $current, $type, $new
      )
    );
  }

  $poll_fd_masks{$fileno} = $new;
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  my $self = shift;

  # Check for a hung kernel.
  $self->_test_if_kernel_is_idle();

  # Set the poll timeout based on current queue conditions.  If there
  # are FIFO events, then the poll timeout is zero and move on.
  # Otherwise set the poll timeout until the next pending event, if
  # there are any.  If nothing is waiting, set the timeout for some
  # constant number of seconds.

  my $now = time();

  my $timeout = $self->get_next_event_time();
  if (defined $timeout) {
    $timeout -= $now;
    $timeout = MINIMUM_POLL_TIMEOUT if $timeout < MINIMUM_POLL_TIMEOUT;
  }
  else {
    $timeout = 3600;
  }

  if (TRACE_EVENTS) {
    POE::Kernel::_warn(
      '<ev> Kernel::run() iterating.  ' .
      sprintf(
        "now(%.4f) timeout(%.4f) then(%.4f)\n",
        $now-$start_time, $timeout, ($now-$start_time)+$timeout
       )
    );
  }

  my @filenos = %poll_fd_masks;

  if (TRACE_FILES) {
    foreach (sort { $a<=>$b} keys %poll_fd_masks) {
      my @types;
      push @types, "plain-file"        if -f;
      push @types, "directory"         if -d;
      push @types, "symlink"           if -l;
      push @types, "pipe"              if -p;
      push @types, "socket"            if -S;
      push @types, "block-special"     if -b;
      push @types, "character-special" if -c;
      push @types, "tty"               if -t;
      my @modes;
      my $flags = $poll_fd_masks{$_};
      push @modes, 'r' if $flags & (POLLIN | POLLHUP | POLLERR);
      push @modes, 'w' if $flags & (POLLOUT | POLLHUP | POLLERR);
      push @modes, 'x' if $flags & (POLLRDBAND | POLLHUP | POLLERR);
      POE::Kernel::_warn(
        "<fh> file descriptor $_ = modes(@modes) types(@types)\n"
      );
    }
  }

  # Avoid looking at filehandles if we don't need to.  -><- The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if ($timeout or @filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = IO::Poll::_poll($timeout * 1000, @filenos);

      if (ASSERT_FILES) {
        if ($hits < 0) {
          POE::Kernel::_trap("<fh> poll returned $hits (error): $!")
            unless ( ($! == EINPROGRESS) or
                     ($! == EWOULDBLOCK) or
                     ($! == EINTR)
                   );
        }
      }

      if (TRACE_FILES) {
        if ($hits > 0) {
          POE::Kernel::_warn "<fh> poll hits = $hits\n";
        }
        elsif ($hits == 0) {
          POE::Kernel::_warn "<fh> poll timed out...\n";
        }
      }

      # If poll has seen filehandle activity, then gather up the
      # active filehandles and synchronously dispatch events to the
      # appropriate handlers.

      if ($hits > 0) {

        # This is where they're gathered.

        while (@filenos) {
          my ($fd, $got_mask) = splice(@filenos, 0, 2);
          next unless $got_mask;

          my $watch_mask = $poll_fd_masks{$fd};
          if ( $watch_mask & POLLIN and
               $got_mask & (POLLIN | POLLHUP | POLLERR)
             ) {
            if (TRACE_FILES) {
              POE::Kernel::_warn "<fh> enqueuing read for fileno $fd";
            }

            $self->_data_handle_enqueue_ready(MODE_RD, $fd);
          }

          if ( $watch_mask & POLLOUT and
               $got_mask & (POLLOUT | POLLHUP | POLLERR)
             ) {
            if (TRACE_FILES) {
              POE::Kernel::_warn "<fh> enqueuing write for fileno $fd";
            }

            $self->_data_handle_enqueue_ready(MODE_WR, $fd);
          }

          if ( $watch_mask & POLLRDBAND and
               $got_mask & (POLLRDBAND | POLLHUP | POLLERR)
             ) {
            if (TRACE_FILES) {
              POE::Kernel::_warn "<fh> enqueuing expedite for fileno $fd";
            }

            $self->_data_handle_enqueue_ready(MODE_EX, $fd);
          }
        }
      }
    }

    # No filehandles to poll on.  Try to sleep instead.  Use sleep()
    # itself on MSWin32.  Use a dummy four-argument select() everywhere
    # else.

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

### Run for as long as there are sessions to service.

sub loop_run {
  my $self = shift;
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

POE::Loop::Event - a bridge that supports IO::Poll from POE

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<IO::Poll>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
