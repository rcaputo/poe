# $Id$

package POE::Wheel;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

#------------------------------------------------------------------------------
1;

__END__

=head1 NAME

POE::Wheel - POE Protocol Logic Abstraction

=head1 SYNOPSIS

  $wheel = new POE::Wheel::Something( ... )
  $wheel->put($some_logical_data_chunks);

=head1 DESCRIPTION

Wheels provide standard, reusable protocol logic.  They use filters
and drivers to do the actual work.  They are designed to manage the
resources and objects they are given, so programs generally should not
bother keeping separate references to them.

Wheels mainly work with files.  They usually add and remove states to
handle select events in the sessions that create them.  Creating a
wheel on behalf of another session will not do what you expect.
Likewise, calling another wheel's methods will do Strange Things,
because a certain level of privacy was assumed while writing them.

=head1 PUBLIC WHEEL METHODS

=over 4

=item *

POE::Wheel::new( ... )

The new() method creates and initializes a new wheel.  Part of a
wheel's initialization involves adding states to its parent session
(the one that is calling the new() method) and registering them with
the kernel (usually through POE::Kernel::select() calls).
Instantiating wheels on behalf of other sessions will not work as
expected, if at all.

Because wheels have wildly different purposes, they tend also to have
wildly different constructors.

=item *

POE::Wheel::DESTROY()

The DESTROY() method removes the wheel's states from its parent
session and cleans up the wheel's other resources.  It's called
implicitly when the parent session lets go of the wheel's reference.

B<Important note:> When passing a filehandle between wheels, you must
ensure that the old wheel is destroyed before creating the new one.
This is necessary because destruction of the old wheel will remove all
the selects for the filehandle.  That will undo any selects set by a
new wheel, preventing the new wheel from seeing any file activity.

=item *

POE::Wheel::put()

Wheels hide their resources behind a high-level interface.  Part of
that interface is the put() method, which calls Filter and Driver
put() methods as needed.

=item *

POE::Wheel::event(...)

Wheels emit events for different things.  The event() method lets a
session change the events its wheels emit at runtime.

The event() method's parameters are pairs of event types (defined by
wheels' /^.*State$/ constructor parameters) and events to emit.  If
the event to emit is undef, then the wheel won't emit an event for the
condition.

For example:

  $wheel->event( InputState   => 'new_input_state',
                 ErrorState   => undef,
                 FlushedState => 'new_flushed_state',
               );

=back

=head1 SEE ALSO

POE::Wheel; POE::Wheel::FollowTail; POE::Wheel::ListenAccept;
POE::Wheel::ReadWrite; POE::Wheel::SocketFactory

=head1 BUGS

Wheels are fine for what they do, but they tend to be limiting when
they're used in more interesting ways.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
