# $Id$

package POE::Filter;

use strict;
use Carp;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
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
implement them.  Specific filters may have additional methods.

=over 2

=item new

new() creates and initializes a new filter.  Specific filters may have
different constructor parameters.

=item get ARRAYREF

get() translates raw data into records as defined by the filter.  It
accepts a reference to an array of raw data chunks, and it returns a
reference to an array of complete records.

Drivers' get() methods return ARRAYREFs of raw data chunks suitable
for passing to filters' put() methods.

  my $records = $filter->get( $driver->get( $filehandle ) );

There needn't be a 1:1 ratio between raw data and logical records.
Some filters buffer partial records until they are completed in
subsequent get() calls.

get() returns a reference to an empty array if the stream doesn't
include enough information to complete a record.

=item put ARRAYREF

put() serializes records into a form that may be written to a file or
sent across a socket.  It accepts a reference to a list of records,
and it returns a reference to a list of stream chunks.

The list reference it returns may be passed directly to a driver.

  $driver->put( $filter->put( \@records ) );

=item get_pending

get_pending() returns a filter's partial input buffer, clearing it in
the process.  The ReadWrite wheel uses this for hot-swapping filters;
it gives partial input buffers to the next filter.

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
