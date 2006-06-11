# $Id$

# Tk-Perl event loop bridge for POE::Kernel.

package POE::Loop::Tk;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

# Include common things.
use POE::Loop::PerlSignals;
use POE::Loop::TkCommon;

use Tk 800.021;
use 5.00503;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Hand off to POE::Loop::TkActiveState if we're running under
# ActivePerl.
BEGIN {
  if ($^O eq "MSWin32") {
    require POE::Loop::TkActiveState;
    POE::Loop::TkActiveState->import();
    die "not really dying";
  }
}

my @_fileno_refcount;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  $poe_main_window = Tk::MainWindow->new();
  die "could not create a main Tk window" unless defined $poe_main_window;
  $self->signal_ui_destroy($poe_main_window);
}

sub loop_finalize {
  my $self = shift;
  $self->loop_ignore_all_signals();
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  my $tk_mode;
  if ($mode == MODE_RD) {
    $tk_mode = 'readable';
  }
  elsif ($mode == MODE_WR) {
    $tk_mode = 'writable';
  }
  else {
    # The Tk documentation implies by omission that expedited
    # filehandles aren't, uh, handled.  This is part 1 of 2.
    confess "Tk does not support expedited filehandles";
  }

  # Start a filehandle watcher.

  $poe_main_window->fileevent(
    $handle,
    $tk_mode,

    # The handle is wrapped in quotes here to stringify it.  For some
    # reason, it seems to work as a filehandle anyway, and it breaks
    # reference counting.  For filehandles, then, this is truly a safe
    # (strict ok? warn ok? seems so!) weak reference.
    [ \&_loop_select_callback, $fileno, $mode ],
  );

  $_fileno_refcount[fileno $handle]++;
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $mode == MODE_EX;

  # The fileno refcount just dropped to 0.  Remove the handle from
  # Tk's file watchers.

  unless (--$_fileno_refcount[fileno $handle]) {
    $poe_main_window->fileevent(
      $handle,

      # It can only be MODE_RD or MODE_WR here (MODE_EX is checked a
      # few lines up).
      ( ( $mode == MODE_RD ) ? 'readable' : 'writable' ),

      # Nothing here!  Callback all gone!
      ''
    );
  }

  # Otherwise we have other things watching the handle.  Go into Tk's
  # undocumented guts to disable just this watcher without hosing the
  # entire fileevent thing.

  else {
    my $tk_file_io = tied( *$handle );
    die "whoops; no tk file io object" unless defined $tk_file_io;
    $tk_file_io->handler(
      ( ( $mode == MODE_RD )
        ? Tk::Event::IO::READABLE()
        : Tk::Event::IO::WRITABLE()
      ),
      ''
    );
  }
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;

  my $tk_mode;
  if ($mode == MODE_RD) {
    $tk_mode = Tk::Event::IO::READABLE();
  }
  elsif ($mode == MODE_WR) {
    $tk_mode = Tk::Event::IO::WRITABLE();
  }
  else {
    # The Tk documentation implies by omission that expedited
    # filehandles aren't, uh, handled.  This is part 2 of 2.
    confess "Tk does not support expedited filehandles";
  }

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;

  $tk_file_io->handler($tk_mode, "");
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  # The Tk documentation implies by omission that expedited
  # filehandles aren't, uh, handled.  This is part 2 of 2.
  confess "Tk does not support expedited filehandles"
    if $mode == MODE_EX;

  # Use an internal work-around to fileevent quirks.
  my $tk_file_io = tied( *$handle );
  die "whoops; no tk file io object" unless defined $tk_file_io;

  $tk_file_io->handler(
    ( ( $mode == MODE_RD )
      ? Tk::Event::IO::READABLE()
      : Tk::Event::IO::WRITABLE()
    ),
    [ \&_loop_select_callback,
      $fileno,
      $mode,
    ]
  );
}

# Tk filehandle callback to dispatch selects.
sub _loop_select_callback {
  my ($fileno, $mode) = @_;
  $poe_kernel->_data_handle_enqueue_ready($mode, $fileno);
  $poe_kernel->_test_if_kernel_is_idle();
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
