#!/usr/bin/perl -w
# $Id$

# A simple Tk application, using POE.  Please see notes after __END__
# for design issues.

use strict;
use lib '..';
use lib '/usr/mysrc/Tk800.021/blib';
use lib '/usr/mysrc/Tk800.021/blib/lib';
use lib '/usr/mysrc/Tk800.021/blib/arch';

# Tk stuff fires a *lot* of events.  Don't trace unless you mean it.
# sub POE::Kernel::TRACE_DEFAULT () { 1 }

# Assertions are okay.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

# It's important to use Tk before using POE.  This way Tk is visible
# to POE at compile time, so it can adjust its behavior accordingly.
# This technique can be extended to other event loops.
use Tk;
use POE qw( Wheel::ReadWrite Filter::Line Driver::SysRW );
use Symbol;

#==============================================================================
# The main UI.  This was plain Perl/Tk to begin with, but it's
# gradually migrating to POE/Tk as POE's feature set engorges itself
# with the blood of its enemies.  Or something.

# A POE session that embodies the UI.

sub ui_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  $heap->{timers_running} = 0;

  # Some scalars from which we'll be making anonymous references.
  my $fast_text = 0;
  my $slow_text = 0;
  my $idle_text = 0;

  # A pipe.

  $heap->{pipe_read}  = gensym();
  $heap->{pipe_write} = gensym();
  pipe($heap->{pipe_read}, $heap->{pipe_write}) or die "can't create pipe: $!";

  $heap->{pipe_wheel} =
    POE::Wheel::ReadWrite->new
      ( InputHandle  => $heap->{pipe_read},
        OutputHandle => $heap->{pipe_write},
        Filter       => POE::Filter::Line->new(),
        Driver       => POE::Driver::SysRW->new(),
        InputState   => 'ev_pipe_read',
        ErrorState   => 'ev_pipe_error',
      );

  # An entry field.  Things entered here are written to the writable
  # end of the pipe.

  $heap->{pipe_entry} = $poe_tk_main_window->Entry( -width => 30 );
  $heap->{pipe_entry}->insert( 0, scalar localtime() );
  $heap->{pipe_entry}->pack;

  # A button.  Pressing it writes what's in the entry field into the
  # pipe.

  $poe_tk_main_window->Button
    ( -text => 'Write Entry to Pipe',
      -command => $session->postback( 'ev_pipe_write' )
    )->pack;

  # A listbox.  It contains the last 5 things fetched from the
  # readable end of the pipe.

  $heap->{pipe_tail_list} = $poe_tk_main_window->Listbox
    ( -height => 5, -width => 30
    );
  for my $i (0..4) {
    $heap->{pipe_tail_list}->insert( 'end', "starting line $i" );
  }
  $heap->{pipe_tail_list}->pack;

  # A fast timed counter.

  $heap->{fast_text} = \$fast_text;
  $heap->{fast_widget} =
    $poe_tk_main_window->Label( -textvariable => $heap->{fast_text} );
  $heap->{fast_widget}->pack;

  # A slow timed counter.

  $heap->{slow_text} = \$slow_text;
  $heap->{slow_widget} =
    $poe_tk_main_window->Label( -textvariable => $heap->{slow_text} );
  $heap->{slow_widget}->pack;

  # An idle counter.

  $heap->{idle_text} = \$idle_text;
  $heap->{idle_widget} =
    $poe_tk_main_window->Label( -textvariable => $heap->{idle_text} );
  $heap->{idle_widget}->pack;

  # Buttons to start and stop the timed counters.

  $poe_tk_main_window->Button
    ( -text => 'Begin Slow and Fast Alarm Counters',
      -command => $session->postback( 'ev_counters_begin' )
    )->pack;
  $poe_tk_main_window->Button
    ( -text => 'Stop Slow and Fast Alarm Counters',
      -command => $session->postback( 'ev_counters_cease' )
    )->pack;

  # A button to exit the program would be nice! :)

  $poe_tk_main_window->Button
    ( -text => 'Exit',
      -command => sub { $poe_tk_main_window->destroy }
    )->pack;

  # Begin some callbacks.

  $poe_tk_main_window->bind( '<FocusIn>',
                             $session->postback( 'ev_idle_count_begin' )
                           );

  $poe_tk_main_window->bind( '<FocusOut>',
                             $session->postback( 'ev_idle_count_cease' )
                           );
}

sub ui_stop {
  print "Session ", $_[SESSION]->ID, " is stopped.\n";
}

sub ui_signal {
  my ($session, $signal) = @_[SESSION, ARG0];
  print "Session ", $session->ID, " caught signal $signal.\n";
}

### Timed counters logic.

sub ui_slow_counter_increment {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{slow_text}}++;
  $kernel->delay( 'ev_slow_count', 0.2 );
}

sub ui_fast_counter_increment {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  ${$heap->{fast_text}}++;
  $kernel->delay( 'ev_fast_count', 0.1 );
}

sub ui_timed_counters_begin {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  print "counters' begin button pressed\n";
  unless ($heap->{timers_running}) {
    $heap->{timers_running} = 1;
    $kernel->delay( 'ev_fast_count', 0.1 );
    $kernel->delay( 'ev_slow_count', 0.2 );
  }
}

sub ui_timed_counters_cease {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  print "counters' cease button pressed\n";
  if ($heap->{timers_running}) {
    $heap->{timers_running} = 0;
    $kernel->delay( 'ev_fast_count' );
    $kernel->delay( 'ev_slow_count' );
  }
}

### Focused idle counter.

sub ui_focus_idle_counter_begin {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  unless ($heap->{has_focus}) {
    $heap->{has_focus} = 1;
    $kernel->yield( 'ev_idle_count' );
  }
}

sub ui_focus_idle_counter_cease {
  $_[HEAP]->{has_focus} = 0;
}

sub ui_focus_idle_counter_increment {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  if ($heap->{has_focus}) {
    ${$heap->{idle_text}}++;
    $kernel->yield( 'ev_idle_count' );
  }
}

### Select stuff.

sub ui_ev_pipe_write {
  my $heap = $_[HEAP];
  my $text = $heap->{pipe_entry}->get();
  $heap->{pipe_entry}->delete( 0, length($text) );
  $heap->{pipe_entry}->insert( 0, scalar localtime() );
  $heap->{pipe_wheel}->put($text);
}

sub ui_ev_pipe_read {
  my ($heap, $line) = @_[HEAP, ARG0];

  $heap->{pipe_tail_list}->delete(0);
  $heap->{pipe_tail_list}->insert( 'end', $line );
}

sub ui_ev_pipe_error {
  my ($heap, $op, $en, $es) = @_[HEAP, ARG0..ARG2];
  $heap->{pipe_tail_list}->delete(0);
  $heap->{pipe_tail_list}->insert( 'end', "pipe got $op error $en: $es" );
}

### Main loop, or something.

POE::Session->create
  ( inline_states =>
    { _start  => \&ui_start,
      _stop   => \&ui_stop,
      _signal => \&ui_signal,

      ### Timed counters states, including buttons.

      ev_counters_begin => \&ui_timed_counters_begin,
      ev_counters_cease => \&ui_timed_counters_cease,
      ev_fast_count     => \&ui_fast_counter_increment,
      ev_slow_count     => \&ui_slow_counter_increment,

      ### Idle counter states.

      ev_idle_count       => \&ui_focus_idle_counter_increment,
      ev_idle_count_begin => \&ui_focus_idle_counter_begin,
      ev_idle_count_cease => \&ui_focus_idle_counter_cease,

      ### Pipe watcher.

      ev_pipe_error => \&ui_ev_pipe_error,
      ev_pipe_read  => \&ui_ev_pipe_read,
      ev_pipe_write => \&ui_ev_pipe_write,
    }
  );

# Run the thing.

$poe_kernel->run();

exit;

__END__

* Listed in approximate order of importance:

Using Tk does not keep a Session alive.

  The act of managing a Tk widget (most often a Window or MainWindow,
  I suppose) does not hold a reference count for the session.

  POE needs to know that a session is managing (or being managed by?)
  Tk widgets.  In other words, some sort of owner/manager/parent
  relationship must be established and maintained.

  POE needs to know that a session is watching widgets, so there must
  be some basic Tk-aware code in either POE::Kernel or a plugged-in
  watcher.

  POE::TkWatch($widget_ref) could be a plugged-in watcher.  I know of
  three possible behaviors for this hypothetical watcher:

  1. Grab every callback, catch the Tk events and re-throw them as POE
  events.

  2. Ignore everything about Tk and expect the session to do something
  about it.

  3. Register an OnDestroy callback that does GC and reference count
  maintenance when the widget goes away.

POE could use a generic reference count manager.  Possibly:

  $kernel->refcount_allocate( $tag, $bitmask_flags ); Register a
  reference count, identified by a tag ($tag).  One of $bitmask_flags'
  bits would tell POE whether the reference count keeps the session
  alive.  DEB_REFCOUNT would enable leak detection for these as well.

  (refcount_allocate is redundant; if we use a hash, then the first
  increment will also allocate)

  $kernel->refcount_increment( $tag ); That would increment the
  reference count associated with $tag (previously allocated).

  $kernel->refcount_decrement( $tag ); This decrements the reference
  count.

  $kernel->refcount_free( $tag ); Frees a reference count tag,
  optionally checking for leakage (if DEB_REFCOUNT is enabled).

  Specific resource classes could build from this simple API.  For
  example, POE::TkWatch to watch Tk widgets.

POE can run out of things to do before Tk does.  What occurs then?

  This can be solved if there is a main session that implements the UI
  and child sessions that do things.  Under normal circumstances, the
  main session cannot exit until the children do.

  Well, no.  I mean, you can always post a _stop at it, stopping it
  dead in its tracks, but that's not very friendly.

Tk can run out of things to do before POE does.  What occurs then?

  The main window's OnDestroy callback can shut down POE, but this may
  mean that running tasks don't finish.

  Then again, if someone is shutting down the program, I guess they
  really want it to be shut down.  I suppose in this case we can
  create another SIGZOMBIE-like fatal pseudosignal.

  Still, enough of a POE loop needs to be active to dispatch that.
  Oh, the irony!  I guess POE can swap in its own event loop at this
  point and use it to clean things up.

Tk callbacks may want to fire POE events.  They will need session
references to determine the events' destinations.  This can cause
circular references where Tk has a session reference, and the session
has a Tk reference.

  Tk callbacks can reference POE sessions by alias.  Setting up
  aliases seems wrong, though.  It almost feels like there's a better
  way to do this but I just haven't spotted it yet.

People may expect Tk callbacks as POE events.  People may wish to post
events at Tk widgets, instead of calling options on them.

  These are great ideas, but they involve a lot of Tk interfacing.
  For example, I could subclass every Tk thing with POE-aware methods.
  That sucks, though, because it means new widgets don't automatically
  work.

  I think this just means I haven't found the right way to glue the
  two interfaces together yet.  It really feels that way, and I
  suspect there's a good way to do it that I haven't yet found.

Nasty solution #1:

  Replace all the Tk widgets with POE::Tk wrappers that do the
  resource management for us and invoke the real Tk widgets
  underneath.  This sucks in a Big Way because it limits usable
  widgets to the ones with wrappers.  New widgets would be useless
  until wrappers were written for them.

Observation #1:

  Perhaps not every widget needs a wrapper.  Maybe only the TopLevel
  widgets do.  More to the point, perhaps ONLY TopLevel needs a
  wrapper.  Wedging my own intermediate base class (wrapper) into Tk's
  hierarchy is probably a losing proposition.

Sky: Create a Session::Tk subclass of Session.

  What does this give us?

Require that Tk interfaces be their own sessions, or perhaps a
POE::Component::Tk.

  This creates a hard link between Tk and POE, through that session.
  When Tk goes away, the session does too, but other sessions can
  continue to run at least as long as necessary to shut down.

Sky: I think any proposition to change Tk will be very hard to get
acceptance.

  True.

Sky: Perhaps you could overload the Tk dispatcher to dispatch things
to Poe for a widget that is registred as a "poe" widget?

  This is very promising.

Slave Tk's event queue off POE's.

  This would require a way to peek into Tk's event loop or otherwise
  unblock POE's select() call when a Tk event becomes available.

  The Perl/Tk reference discusses a Tk_RestrictEvents C function that
  allows a filter to be placed on Tk_DoOneEvent.  If there is a Perl
  equivalent, it may allow POE to handle certain events (or at least
  awaken) when Tk is ready to do an event.

Slave POE's event queue off Tk's.

  Rather than keep POE's events in a local queue, they could be posted
  as virtual Tk events back to a controlling widget (possibly
  MainWindow) that represents POE itself.

  The Tk::event documentation goes on about this.

  $main_window->bind( '<<POE>>', [ $poe_kernel => '_tk_dispatch' ] );

How should Tk events be handled by POE?

  I think Tk callbacks (via, say, Tk::bind) should be mapped to POE
  events.

  Like with filehandle selects, they should be called synchronously,
  so that sessions may deal with them ahead of the event queue.  For
  example, this minimizes the time between a button press and its
  effect.

Practical Tk programs implement as much of the widget to widget
interaction as linked commands.

  The canonical example is a scrollbar and a related scrollable
  widget.  It's possible (and it appears quiet easy) to let both of
  these widgets manage each-other with linked events/callbacks.

  POE needn't be concerned with these events; it just needs to know
  when the user requests something done.

#------------------------------------------------------------------------------
# Some good, practical notes follow.  These are a rethink of things,
# based on more research into Tk and POE, with some prodding by the
# more promising ideas from above.  The integration is starting to
# look not only possible, but sensible and practical.
#------------------------------------------------------------------------------

POE/Tk interface contact point #1.

  POE and Tk touch where POE states create widgets and store
  references to them.

  POE must be aware that the session is awaiting Tk things, so that
  the session isn't accidentally garbage collected.  This is where the
  reference counting mechanism comes in.

  my $window = MainWindow->new();
  $window->OnDestroy( $session->postback( 'window gone') );


POE/Tk interface contact point #2.

  POE and Tk touch where Tk widgets call POE states.

  Since these should be synchronous, it's not necessary for the
  callbacks to go through POE.  They may call subs directly, and the
  subs can do things that post events.

  Moot!  POE::Kernel::alias_resolve can translate stringified session
  references to blessed ones.  So Tk widgets can be given the
  stringified ones, which act like weak references, without creating
  baaaad old circular references.

  This issue is SOLVED!  w00t!  Borrowing from the example, the format
  would look like this:

  $window->Button( -text => 'Begin',
                   -command => sub { $kernel->post( $session->ID, 'begin' ) }
                 )->pack;

  That's still tedious, but at least it's doable!  I'll need a
  shortcut!  How about a POE::Session method:

  sub postback {
    my ($self, $event, @etc) = @_;
    return sub { $poe_kernel->post( $self->ID, $event, @etc ); };
  }

  Then the invocation would look like this:

  $window->Button( -text => 'Begin',
                   -command => $session->postback( $event, @etc ),
                 )->pack;

  This is not Tk specific, so it's generally useful for other types of
  "weak" callbacks.

