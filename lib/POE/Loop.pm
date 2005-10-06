# $Id$

package POE::Loop;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use Carp qw(croak);

sub new {
  my $type = shift;
  croak "$type is a virtual base class and not meant to be used directly";
}

1;

__END__

=head1 NAME

POE::Loop - documentation for POE's event loop bridge interface

=head1 SYNOPSIS

  $kernel->loop_initialize();
  $kernel->loop_finalize();
  $kernel->loop_do_timeslice();
  $kernel->loop_run();
  $kernel->loop_halt();

  $kernel->loop_watch_signal($signal_name);
  $kernel->loop_ignore_signal($signal_name);
  $kernel->loop_attach_uidestroy($gui_window);

  $kernel->loop_resume_time_watcher($next_time);
  $kernel->loop_reset_time_watcher($next_time);
  $kernel->loop_pause_time_watcher();

  $kernel->loop_watch_filehandle($handle, $mode);
  $kernel->loop_ignore_filehandle($handle, $mode);
  $kernel->loop_pause_filehandle($handle, $mode);
  $kernel->loop_resume_filehandle($handle, $mode);

=head1 DESCRIPTION

POE's runtime kernel abstraction uses the "bridge" pattern to
encapsulate services provided by different event loops.  This
abstraction allows POE to cooperate with several event loops and
support new ones with a minimum amount of work.

POE relies on a relatively small number of event loop services: signal
callbacks, time or alarm callbacks, and filehandle activity callbacks.

The rest of the bridge interface is administrative trivia such as
initializing, executing, and finalizing event loop.

POE::Kernel uses POE::Loop classes internally as a result of detecting
which event loop is loaded before POE is.  You should almost never
need to C<use> a POE::Loop class directly, although there is some
early support for doing so in cases where it's absolutely necessary.

See L<POE::Kernel/"Using POE with Other Event Loops"> for details
about actually using POE with other event loops.

=head1 GENERAL NOTES

An event loop bridge is not a proper object in itself.  Rather, it is
a suite of functions that are defined within the POE::Kernel
namespace.  A bridge is a plugged-in part of POE::Kernel itself.  Its
functions are proper POE::Kernel methods.

Each bridge first defines its own namespace and version within it.
This way CPAN and other things can track its version.

  # $Id$

  use strict;

  # YourToolkit bridge for POE::Kernel;

  package POE::Loop::YourToolkit;

  use vars qw($VERSION);
  $VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

  package POE::Kernel;

  ... private lexical data and functions defined here ...

  1;

  __END__

  =head1 NAME

  ... documentation goes here ...

  =cut

The public interface for loop bridges is broken into four parts:
administrative functions, signal functions, time functions, and
filehandle functions.  They will be described in detail shortly.

Bridges use lexical variables to keep track of things.  The types and
number of variables depends on the needs of each event loop.  For
example, POE::Loop::Select keeps bit vectors for its select() call.
POE::Loop::Gtk tracks a single time watcher and multiple file watchers
for each file descriptor.

Bridges often employ private functions as callbacks from their event
loops.  The Event, Gtk, and Tk bridges do this.

Developers should look at existing bridges to get a feel for things.
The C<-m> flag for perldoc will show a module in its entirety.

  perldoc -m POE::Loop::Select
  perldoc -m POE::Loop::Gtk
  ...

=head1 ADMINISTRATIVE FUNCTIONS

These functions initialize and finalize an event loop, run the loop to
process events, and halt it.

=over 2

=item loop_initialize

Initialize the event loop.  Graphical toolkits especially need some
sort of init() call or sequence to set up.  For example,
POE::Loop::Gtk implements loop_initialize() like this.

  sub loop_initialize {
    Gtk->init;
  }

POE::Loop::Select does a little more work.

  sub loop_initialize {
    @loop_vectors = ( '', '', '' );
    vec($loop_vectors[MODE_RD], 0, 1) = 0;
    vec($loop_vectors[MODE_WR], 0, 1) = 0;
    vec($loop_vectors[MODE_EX], 0, 1) = 0;
  }

=item loop_finalize

Finalize the event loop.  Most event loops do not require anything
here since they have already stopped by the time loop_finalize() is
called.  However, this is a good place to check that a bridge has not
leaked memory or data.  This example comes from POE::Loop::Event.

  sub loop_finalize {
    foreach my $fd (0..$#fileno_watcher) {
      next unless defined $fileno_watcher[$fd];
      foreach my $mode (MODE_RD, MODE_WR, MODE_EX) {
        warn "Fileno $fd / mode $mode has a watcher at loop_finalize"
          if defined $fileno_watcher[$fd]->[$mode];
      }
    }
  }

=item loop_do_timeslice

Wait for time to pass or new events to occur, and dispatch events
which are due.  If the underlying event loop does these things, then
loop_do_timeslice() either provide- minimal glue for them or does
nothing.

For example, the loop_do_timeslice() function for the Select bridge
sets up and calls select().  If any files or other resources become
active, it enqueues events for them.  Finally, it triggers dispatch
for any events are due.

On the other hand, the Gtk event loop handles all this, so
loop_do_timeslice() is empty for the Gtk bridge.

A sample loop_do_timeslice() is not presented here because it would
either be quite large or empty.  See the bridges for Poll and Select
for large ones.  The Event, Gtk, and Tk bridges are good examples of
empty ones.

=item loop_run

Run an event loop until POE has no more sessions to handle events.
This function tends to be quite small.  For example, the Poll bridge
uses:

  sub loop_run {
    my $self = shift;
    while ($self->_data_ses_count()) {
      $self->loop_do_timeslice();
    }
  }

This function is even more trivial when an event loop handles it.
This is from the Gtk bridge:

  sub loop_run {
    Gtk->main;
  }

=item loop_halt

Halt an event loop, especially one which does not know about POE.
This tends to be an empty function for loops written in the bridges
themselves (Poll, Select) and a trivial function for ones that have
their own main loops.

For example, the loop_run() function in the Poll bridge exits when
sessions have run out, so its loop_halt() function is empty:

  sub loop_halt {
    # does nothing
  }

Gtk, however, needs to be stopped because it does not know when POE is
done.

  sub loop_halt {
    Gtk->main_quit();
  }

=back

=head1 SIGNAL FUNCTIONS

These functions enable and disable signal watchers.

=over 2

=item loop_watch_signal SIGNAL_NAME

Watch for a given SIGNAL_NAME, most likely by registering a signal
handler.  Signal names are the ones included in %SIG.  That is, they
are the UNIX signal names with the leading "SIG" removed.

Most event loops do not have native signal watchers, so it is up to
their bridges to register %SIG handlers.  Some bridges, such as
POE::Loop::Event, register callbacks for various signals.

There are three types of signal handlers:

CHLD/CLD handlers, when managed by the bridges themselves, poll for
exited children.  POE::Kernel does most of this, but
loop_watch_signal() still needs to start the process.

PIPE handlers.  The PIPE signal event must be sent to the session that
is active when the signal occurred.

Everything else.  Signal events for everything else are sent to
POE::Kernel, where they are distributed to every session.

The loop_watch_signal() function tends to be very long, so an example
is not presented here.  The Event and Select bridges have good
examples, though.

=item loop_ignore_signal SIGNAL_NAME

Stop watching SIGNAL_NAME.  This usually resets the %SIG entry for
SIGNAL_NAME to DEFAULT.  In the Event bridge, however, it stops and
removes a watcher for the signal.

The Select bridge:

  sub loop_ignore_signal {
    my ($self, $signal) = @_;
    $SIG{$signal} = "DEFAULT";
  }

The Event bridge:

  sub loop_ignore_signal {
    my ($self, $signal) = @_;
    if (defined $signal_watcher{$signal}) {
      $signal_watcher{$signal}->stop();
      delete $signal_watcher{$signal};
    }
  }

=item loop_attach_uidestroy WINDOW

Send a UIDESTROY signal when WINDOW is closed.  The UIDESTROY signal
is used to shut down a POE program when its user interface is
destroyed.

This function is only meaningful in bridges that interface with
graphical toolkits.  All other bridges leave loop_attach_uidestroy()
empty.  See POE::Loop::Gtk and POE::Loop::Tk for examples.

=back

=head1 ALARM OR TIME FUNCTIONS

These functions enable and disable a time watcher or alarm in the
substrate.  POE only requires one, which is reused or re-created as
necessary.

Most event loops trigger callbacks when time has passed.  Bridges for
this kind of loop will need to register and unregister a callback as
necessary.  The callback, in turn, will dispatch due events and do
some other maintenance.

The bridge time functions accept NEXT_EVENT_TIME in the form of a UNIX
epoch time.  Event times may contain fractional seconds.  Time
functions may be required to translate times from the UNIX epoch into
whatever representation an underlying event loop requires.

=over 2

=item loop_resume_time_watcher NEXT_EVENT_TIME

Resume an already active time watcher.  Used with
loop_pause_time_watcher() to provide lightweight timer toggling.
NEXT_EVENT_TIME is the UNIX epoch time of the next event in the queue.
This function is used by bridges that set time watchers in other event
loop libraries.  For example, Gtk uses this:

  sub loop_resume_time_watcher {
    my ($self, $next_time) = @_;
    $next_time -= time();
    $next_time *= 1000;
    $next_time = 0 if $next_time < 0;
    $_watcher_timer = Gtk->timeout_add( $next_time,
                                        \&_loop_event_callback
                                      );
  }

It is often empty in bridges that implement their own event loops.

=item loop_reset_time_watcher NEXT_EVENT_TIME

Reset a time watcher, often by stopping or destroying an existing one
and creating a new one in its place.  This function has the same
semantics as (and is often implemented in terms of)
loop_resume_time_watcher().  It is usually more expensive than that
function, however.  Again, from Gtk:

  sub loop_reset_time_watcher {
    my ($self, $next_time) = @_;
    Gtk->timeout_remove($_watcher_timer);
    undef $_watcher_timer;
    $self->loop_resume_time_watcher($next_time);
  }

=item loop_pause_time_watcher

Pause a time watcher.  This should be done without destroying the
timer, if the underlying event loop supports that.

POE::Loop::Event supports pausing a timer:

  sub loop_pause_time_watcher {
    $_watcher_timer->stop();
  }

=back

=head1 FILE ACTIVITY FUNCTIONS

These functions enable and disable file activity watchers.  The pause
and resume functions are lightweight versions of ignore and watch.
They are used to quickly toggle the state of a file activity watcher
without incurring the overhead of destroying and creating them
entirely.

All the functions take the same two parameters: a file HANDLE and a
file access MODE.

Modes may be MODE_RD, MODE_WR, or MODE_EX.  These constants are
defined by POE::Kernel and correspond to read, write, or exceptions.

POE calls MODE_EX "expedited" because it often signals that a file is
ready for out-of-band information.  Not all event loops handle
MODE_EX.  For example, Tk:

  sub loop_watch_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);

    # The Tk documentation implies by omission that expedited
    # filehandles aren't, uh, handled.  This is part 1 of 2.
    confess "Tk does not support expedited filehandles"
      if $mode == MODE_EX;
    ...
  }

=over 2

=item loop_watch_filehandle HANDLE, MODE

Watch a file HANDLE for activity in a given MODE.  Registers the
HANDLE (or, more often its file descriptor via fileno()) in the given
MODE with the underlying event loop.

POE::Loop::Select sets a vec() bit so the next select() call will know
about the handle.  It also tracks which file descriptors it has
active.

  sub loop_watch_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);
    vec($loop_vectors[$mode], $fileno, 1) = 1;
    $loop_filenos{$fileno} |= (1<<$mode);
  }

=item loop_ignore_filehandle HANDLE, MODE

Stop watching a file HANDLE in a given MODE.  Stops (and possibly
destroys) an event watcher corresponding to the HANDLE and MODE.

POE::Loop::IO_Poll manages the descriptor/mode bits out of its
loop_ignore_filehandle() function.  It also performs some cleanup if a
descriptors has been totally ignored.

  sub loop_ignore_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);

    my $type = mode_to_poll($mode);
    my $current = $poll_fd_masks{$fileno} || 0;
    my $new = $current & ~$type;

    if ($new) {
      $poll_fd_masks{$fileno} = $new;
    }
    else {
      delete $poll_fd_masks{$fileno};
    }
  }

=item loop_pause_filehandle HANDLE, MODE

This is a lightweight form of loop_ignore_filehandle().  It is used
along with loop_resume_filehandle() to temporarily toggle a watcher's
state for a file HANDLE in a particular mode.

Some event loops, such as Event.pm, support their file watchers being
disabled and re-enabled without the need to destroy and re-create
entire objects.

  sub loop_pause_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);
    $fileno_watcher[$fileno]->[$mode]->stop();
  }

By comparison, the loop_ignore_filehandle() function for Event.pm
involves canceling and destroying a watcher object.  This can be quite
expensive.

  sub loop_ignore_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);

    # Don't bother removing a select if none was registered.
    if (defined $fileno_watcher[$fileno]->[$mode]) {
      $fileno_watcher[$fileno]->[$mode]->cancel();
      undef $fileno_watcher[$fileno]->[$mode];
    }
  }

=item loop_resume_filehandle HANDLE, MODE

This is a lightweight form of loop_watch_filehandle().  It is used
along with loop_pause_filehandle() to temporarily toggle a a watcher's
state for a file HANDLE in a particular mode.

=back

=head1 HOW POE FINDS LOOP BRIDGES

The first time POE::Kernel is used, it examines the modules currently
loaded in memory and tries to load an appropriate POE::Loop subclass
based on what it discovers.

Firstly, if a POE::Loop class is manually loaded before POE::Kernel,
then that will be used.  End of story.

If one isn't, POE::Kernel iterates through %INC to discover which
modules are already loaded.  For each of them, it tries to load a
similarly-named POE::XS::Loop class, then it tries a corresponding
POE::Loop class.  For example, if IO::Poll is loaded, POE::Kernel
tries

  use POE::XS::Loop::IO_Poll;
  use POE::Loop::IO_Poll;

POE::Loop::Select is the fallback event loop.  It's loaded if none of
the currently loaded modules has its own POE::Loop class.

It can't be repeated often enough that event loops must be loaded
before POE::Kernel.  Otherwise POE::Kernel will not detect the event
loop you want to use, and the wrong POE::Loop class will be loaded.

=head1 SEE ALSO

L<POE>, L<POE::Loop::Event>, L<POE::Loop::Gtk>, L<POE::Loop::IO_Poll>,
L<POE::Loop::Select>, L<POE::Loop::Tk>.

=head1 BUGS

Signal handlers are often repeated between bridges:
http://rt.cpan.org/NoAuth/Bug.html?id=1632

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
