# $Id$

package POE::Wheel;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(croak);

# Used to generate unique IDs for wheels.  This is static data, shared
# by all.
my $next_id = 1;
my %active_wheel_ids;

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

sub allocate_wheel_id {
  while (1) {
    last unless exists $active_wheel_ids{ ++$next_id };
  }
  return $active_wheel_ids{$next_id} = $next_id;
}

sub free_wheel_id {
  my $id = shift;
  delete $active_wheel_ids{$id};
}

#------------------------------------------------------------------------------
1;

__END__

=head1 NAME

POE::Wheel - high-level protocol logic

=head1 SYNOPSIS

  $wheel = POE::Wheel::Something->new( ... );
  $wheel->put($some_logical_data_chunks);

=head1 DESCRIPTION

Wheels are bundles of event handlers (states) which perform common
tasks.  Wheel::FollowTail, for example, contains I/O handlers for
watching a file as it grows and reading the new information when it
appears.

Unlike Components, Wheels do not stand alone.  Each wheel must be
created by a session, and each belongs to their parent session until
it's destroyed.

=head1 COMMON PUBLIC WHEEL METHODS

These methods are the generic Wheel interface, and every filter must
implement them.

=over 2

=item new LOTS_OF_STUFF

new() creates a new wheel, returning the wheels reference.  The new
wheel will continue to run for as long as it exists.  Every wheel has
a different purpose and requires different parameters, so
LOTS_OF_STUFF will vary from one to the next.

=item DESTROY

Perl calls DESTROY when the wheel's last reference is relinquished.
This triggers the wheel's destruction, which stops the wheel and
releases whatever resources it was managing.

=item event TYPE => EVENT_NAME, ...

event() changes the events that a wheel will emit.  Its parameters are
pairs of event TYPEs and the EVENT_NAMEs to emit when each type of
event occurs.

Event TYPEs differ for each wheel, and their manpages discuss them in
greater detail.  EVENT_NAMEs may be undef, in which case a wheel will
stop emitting an event for that TYPE.

This example changes the events to emit on new input and when output
is flushed.  It stops the wheel from emitting events when errors
occur.

  $wheel->event( InputEvent   => 'new_input_event',
                 ErrorEvent   => undef,
                 FlushedEvent => 'new_flushed_event',
               );

=back

=head1 I/O WHEEL COMMON METHODS

These methods are common to I/O wheels.  Some I/O wheels are read-only
and will not have a put() method.

=over 2

=item put LIST

put() sends a LIST of one or more records to the wheel for
transmitting.  Each thing in the LIST is serialized by the wheel's
Filter, and then buffered in the wheel's Driver until it can be
flushed to its filehandle.

=back

=head1 STATIC FUNCTIONS

These functions keep global information about all weels.  They should
be called as normal functions:

  &POE::Wheel::function( ... );

=over 2

=item allocate_wheel_id

allocate_wheel_id() allocates a uniquely identifier for a wheel.
Wheels pass these identifiers back to sessions in their events so that
sessions with several wheels can match events back to other
information.

POE::Wheel keeps track of allocated IDs to avoid collisions.  It's
important to free an ID when it's not in use, or they will consume
memory unnecessarily.

=item free_wheel_id WHEEL_ID

Deallocates a wheel identifier so it may be reused later.  This often
is called from a wheel's destructor.

=back

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

It would be nice if wheels were more like proper Unix streams.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
