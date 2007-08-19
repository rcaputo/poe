# $Id$

# Tk-Perl event loop bridge for POE::Kernel.

# Dummy package so the version is indexed properly.
package POE::Loop::TkActiveState;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

# Merge things into POE::Loop::Tk.
package POE::Loop::Tk;

# Include common things.
use POE::Loop::PerlSignals;
use POE::Loop::TkCommon;

use Tk 800.021;
use 5.00503;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;
use Errno qw(EINPROGRESS EWOULDBLOCK EINTR);

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
my @_fileno_refcount;
my $_handle_poller;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  $poe_main_window = Tk::MainWindow->new();
  die "could not create a main Tk window" unless defined $poe_main_window;
  $self->signal_ui_destroy($poe_main_window);

  # Initialize the vectors as vectors.
  @loop_vectors = ( '', '', '' );
  vec($loop_vectors[MODE_RD], 0, 1) = 0;
  vec($loop_vectors[MODE_WR], 0, 1) = 0;
  vec($loop_vectors[MODE_EX], 0, 1) = 0;

  $_handle_poller = $poe_main_window->after(100, [\&_poll_for_io]);
}

sub loop_finalize {
  my $self = shift;

  # This is "clever" in that it relies on each symbol on the left to
  # be stringified by the => operator.
  my %kernel_modes = (
    MODE_RD => MODE_RD,
    MODE_WR => MODE_WR,
    MODE_EX => MODE_EX,
  );

  while (my ($mode_name, $mode_offset) = each(%kernel_modes)) {
    my $bits = unpack('b*', $loop_vectors[$mode_offset]);
    if (index($bits, '1') >= 0) {
      POE::Kernel::_warn "<rc> LOOP VECTOR LEAK: $mode_name = $bits\a\n";
    }
  }

  $self->loop_ignore_all_signals();
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

# This is the select loop itself.  We do a Bad Thing here by polling
# for socket activity, but it's necessary with ActiveState's Tk.
#
# TODO We should really stop the poller when there are no handles to
# watch and resume it as needed.

sub _poll_for_io {
  if (defined $_handle_poller) {
    $_handle_poller->cancel();
    $_handle_poller = undef;
  }

  # Determine which files are being watched.
  my @filenos = ();
  while (my ($fd, $mask) = each(%loop_filenos)) {
    push(@filenos, $fd) if $mask;
  }

  if (TRACE_FILES) {
    POE::Kernel::_warn(
      "<fh> ,----- SELECT BITS IN -----\n",
      "<fh> | READ    : ", unpack('b*', $loop_vectors[MODE_RD]), "\n",
      "<fh> | WRITE   : ", unpack('b*', $loop_vectors[MODE_WR]), "\n",
      "<fh> | EXPEDITE: ", unpack('b*', $loop_vectors[MODE_EX]), "\n",
      "<fh> `--------------------------\n"
    );
  }

  # Avoid looking at filehandles if we don't need to.  TODO The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if (@filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = CORE::select(
        my $rout = $loop_vectors[MODE_RD],
        my $wout = $loop_vectors[MODE_WR],
        my $eout = $loop_vectors[MODE_EX],
        0,
      );

      if (ASSERT_FILES) {
        if ($hits < 0) {
          POE::Kernel::_trap("<fh> select error: $!") unless (
            ($! == EINPROGRESS) or
            ($! == EWOULDBLOCK) or
            ($! == EINTR)
          );
        }
      }

      if (TRACE_FILES) {
        if ($hits > 0) {
          POE::Kernel::_warn "<fh> select hits = $hits\n";
        }
        elsif ($hits == 0) {
          POE::Kernel::_warn "<fh> select timed out...\n";
        }
        POE::Kernel::_warn(
          "<fh> ,----- SELECT BITS OUT -----\n",
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
            POE::Kernel::_warn(
              "<fh> found pending rd selects: ",
              join( ', ', sort { $a <=> $b } @rd_selects ),
              "\n"
            );
          }
          if (@wr_selects) {
            POE::Kernel::_warn(
              "<sl> found pending wr selects: ",
              join( ', ', sort { $a <=> $b } @wr_selects ),
              "\n"
            );
          }
          if (@ex_selects) {
            POE::Kernel::_warn(
              "<sl> found pending ex selects: ",
              join( ', ', sort { $a <=> $b } @ex_selects ),
              "\n"
            );
          }
        }

        if (ASSERT_FILES) {
          unless (@rd_selects or @wr_selects or @ex_selects) {
            POE::Kernel::_trap(
              "<fh> found no selects, with $hits hits from select???\n"
            );
          }
        }

        # Enqueue the gathered selects, and flag them as temporarily
        # paused.  They'll resume after dispatch.

        @rd_selects and
          $poe_kernel->_data_handle_enqueue_ready(MODE_RD, @rd_selects);
        @wr_selects and
          $poe_kernel->_data_handle_enqueue_ready(MODE_WR, @wr_selects);
        @ex_selects and
          $poe_kernel->_data_handle_enqueue_ready(MODE_EX, @ex_selects);
      }
    }
  }

  # Dispatch whatever events are due.
  $poe_kernel->_data_ev_dispatch_due();

  # Reset the poller.
  $_handle_poller = $poe_main_window->after(100, [\&_poll_for_io]);
}

1;

__END__

=head1 NAME

POE::Loop::Tk - a bridge that supports Tk's event loop from POE

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<Tk>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Redocument.
