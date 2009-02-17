# $Id$

# Plain Perl signal handling is something shared by several event
# loops.  The invariant code has moved out here so that each loop may
# use it without reinventing it.  This will save maintenance and
# shrink the distribution.  Yay!

package POE::Loop::PerlSignals;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;
use POE::Kernel;

# Flag so we know which signals are watched.  Used to reset those
# signals during finalization.
my %signal_watched;

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing generic SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
    __FILE__, __LINE__, undef, time()
  );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing PIPE-like SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
    __FILE__, __LINE__, undef, time()
  );
  $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

# only used under USE_SIGCHLD
sub _loop_signal_handler_chld {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing CHLD-like SIG$_[0] event";
  }

  $poe_kernel->_data_sig_enqueue_poll_event();
  $SIG{$_[0]} = \&_loop_signal_handler_chld;
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my ($self, $signal) = @_;

  $signal_watched{$signal} = 1;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {
    if ( USE_SIGCHLD ) {
      # install, but also trigger once
      # there may be a race condition between forking, and $kernel->sig_chld in
      # which the signal is already delivered
      # and the interval polling mechanism will still generate a SIGCHLD
      # signal, this preserves that behavior
      $SIG{$signal} = \&_loop_signal_handler_chld;
      $self->_data_sig_enqueue_poll_event();
    } else {
      # We should never twiddle $SIG{CH?LD} under POE, unless we want to
      # override system() and friends. --hachi
      # $SIG{$signal} = "DEFAULT";
      $self->_data_sig_begin_polling();
    }
    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_loop_signal_handler_pipe;
    return;
  }

  # Everything else.
  $SIG{$signal} = \&_loop_signal_handler_generic;
}

sub loop_ignore_signal {
  my ($self, $signal) = @_;

  delete $signal_watched{$signal};

  unless ( USE_SIGCHLD ) {
    if ($signal eq 'CHLD' or $signal eq 'CLD') {
      $self->_data_sig_cease_polling();
      # We should never twiddle $SIG{CH?LD} under poe, unless we want to
      # override system() and friends. --hachi
      # $SIG{$signal} = "IGNORE";
      return;
    }
  }

  if ($signal eq 'PIPE') {
    $SIG{$signal} = "IGNORE";
    return;
  }

  $SIG{$signal} = "DEFAULT";
}

sub loop_ignore_all_signals {
  my $self = shift;
  foreach my $signal (keys %signal_watched) {
    $self->loop_ignore_signal($signal);
  }
}

1;

__END__

=head1 NAME

POE::Loop::PerlSignals - common signal handling routines for POE::Loop bridges

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

POE::Loop::PerlSignals implements common code to handle signals for
many different event loops.  Most loops don't handle signals natively,
so this code has been abstracted into a reusable mix-in module.

POE::Loop::PerlSignals follows POE::Loop's public interface for signal
handling.  Therefore, please see L<POE::Loop> for more details.

=head1 SEE ALSO

L<POE>, L<POE::Loop>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
