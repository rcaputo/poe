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

POE::Wheel - high-level protocol logic

=head1 SYNOPSIS

  $wheel = new POE::Wheel::Something( ... )
  $wheel->put($some_logical_data_chunks);

=head1 DESCRIPTION

Wheels contain reusable chunks of high-level logic.  For example,
Wheel::FollowTail contains the algorithm for reading data from the end
of an ever growing file.  Their logic is contained in bundles of
reusable states which they insert into and remove from their owners
during creation and destruction.

Giving a wheel to another session will not transfer related states.
As a result, the original owner will continue receiving a wheel's
events until it's destroyed.

=head1 COMMON PUBLIC WHEEL METHODS

These are the methods that are common to every wheel.

=over 2

=item new LOTS_OF_STUFF

Creates a new wheel, returning its reference.  The reference holder
should keep the wheel reference around until it's ready for the wheel
to stop.

Every wheel has a different purpose and requires different parameters,
so LOTS_OF_STUFF will vary from one to the next.

=item DESTROY

Perl calls DESTROY when the wheel's reference is relinquished.  This
triggers the wheel's destruction, which releases whatever resources it
was managing.

When passing resources from one wheel to another, it's important to
destroy the old wheel before creating the new one.  If the hand-off is
not in this order, the old wheel's destruction will release the
resource B<after> the new one has started watching it.  The new wheel
will then not be watching the resource, even though it ought to be.

=item put LIST

Send a LIST of things through the wheel.  The LIST may only contain
one thing, and that's ok.  Each thing in the LIST is serialized by the
wheel's Filter, and then bufferend until the wheel's Driver can flush
it to a filehandle.

=item event TYPE => STATE_NAME, ...

Changes the states that are called when a wheel notices certain types
of events occurring.

The event() method's parameters are pairs of event TYPEs and the
STATE_NAMEs to call when they occur.  Event TYPEs differ for each
wheel, and their manpages will discuss them in greater detail.
STATE_NAMEs may be undef, in which case the wheel will stop invoking a
state for that TYPE of event.

  $_[HEAP]->{wheel}->event( InputState   => 'new_input_state',
                            ErrorState   => undef,
                            FlushedState => 'new_flushed_state',
                          );

=back

=head1 SEE ALSO

POE::Wheel::FollowTail; POE::Wheel::ListenAccept;
POE::Wheel::ReadWrite; POE::Wheel::SocketFactory.

=head1 BUGS

Wheels really ought to be replaced with a proper stream-based I/O
abstraction and POE::Component classes to replace FollowTail and
SocketFactory.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage for authors and licenses.

=cut
