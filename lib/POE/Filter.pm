# $Id$

package POE::Filter;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use Carp qw(croak);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

# Return all the messages possible to parse in the current input
# buffer.  This uses the newer get_one_start() and get_one(), which is
# implementation dependent.

sub get {
  my ($self, $stream) = @_;
  my @return;

  $self->get_one_start($stream);
  while (1) {
    my $next = $self->get_one();
    last unless @$next;
    push @return, @$next;
  }

  return \@return;
}

sub clone {
  my $self = shift;
  my $buf = (ref($self->[0]) eq 'ARRAY') ? [ ] : '';
  my $nself = bless [
    $buf,                     # BUFFER
    @$self[1..$#$self],  # everything else
  ], ref $self;
  return $nself;    
}

#------------------------------------------------------------------------------
1;

__END__

=head1 NAME

POE::Filter - a protocol abstraction

=head1 SYNOPSIS

  $filter = POE::Filter::Something->new();
  $arrayref_of_logical_chunks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
     $filter->put($arrayref_of_logical_chunks);

=head1 DESCRIPTION

Filters implement generic interfaces to low- and medium-level
protocols.  Wheels use them to communicate in basic ways without
needing to know the details for doing so.  For example, the Line
filter does everything needed to translate incoming streams into lines
and outgoing lines into streams.  Sessions can get on with the
business of using lines.

=head1 PUBLIC FILTER METHODS

These methods are the generic Filter interface, and every filter must
implement them or inherit them from this base class.  Specific filters
may have additional methods.

=over 2

=item new

new() creates and initializes a new filter.  Specific filters may have
different constructor parameters.

=item get ARRAYREF

get() translates raw data into records.  What sort of records is
defined by the specific filter.  The method accepts a reference to an
array of raw data chunks, and it returns a reference to an array of
complete records.  The returned ARRAYREF will be empty if there wasn't
enough information to create a complete record.  Partial records may
be buffered until subsequent get() calls complete them.

  my $records = $filter->get( $driver->get( $filehandle ) );

get() processes and returns as many records as possible.  This is
faster than one record per call, but it introduces race conditions
when switching filters.  If you design filters and intend them to be
switchable, please see get_one_start() and get_one().

=item get_one_start ARRAYREF

=item get_one

These methods are a second interface to a filter's input translation.
They split the usual get() into two stages.

get_one_start() accepts an array reference containing unprocessed
stream chunks.  It adds them to the filter's internal buffer and does
nothing else.

get_one() takes no parameters and returns an ARRAYREF of zero or more
complete records from the filter's buffer.  Unlike the plain get()
method, get_one() is not greedy.  It returns as few records as
possible, preferably just zero or one.

get_one_start() and get_one() reduce or eliminate race conditions when
switching filters in a wheel.

=item put ARRAYREF

put() serializes records into a form that may be written to a file or
sent across a socket.  It accepts a reference to a list of records,
and it returns a reference to a list of stream chunks.

The list reference it returns may be passed directly to a driver.

  $driver->put( $filter->put( \@records ) );

=item get_pending

get_pending() returns a filter's partial input buffer.  Unlike
previous versions, the filter's input buffer is B<not> cleared.  The
ReadWrite wheel uses this for hot-swapping filters; it gives partial
input buffers to the next filter.

get_pending() returns undef if nothing is pending.  This is different
from get() and get_one().

Filters don't have output buffers.  They accept complete records and
immediately pass the serialized information to a driver's queue.

It can be tricky keeping both ends of a socket synchronized during a
filter change.  It's recommended that some sort of handshake protocol
be used to make sure both ends are using the same type of filter at
the same time.

TCP also tries to combine small packets for efficiency's sake.  In a
streaming protocol, a filter change could be embedded between two data
chunks.

  type-1 data
  type-1 data
  change to type-2 filter
  type-2 data
  type-2 data

A driver can easily read that as a single chunk.  It will be passed to
a filter as a single chunk, and that filter (type-1 in the example)
will break the chunk into pieces.  The type-2 data will be interpreted
as type-1 because the ReadWrite wheel hasn't had a chance to switch
filters yet.

Adding a handshake protocol means the sender will wait until a filter
change has been acknowledged before going ahead and sending data in
the new format.

=item clone

clone() makes a copy of the filter, and clears the copy's buffer.

3rd party modules can either implement their own clone() or inherit
from POE::Filter.  If inheriting, the object MUST be an array-ref
AND the first element must be the buffer.  The buffer can be either a
string or an array-ref.

=back

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

In theory, filters should be interchangeable.  In practice, stream and
block protocols tend to be incompatible.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
