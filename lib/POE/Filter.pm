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

POE::Filter - POE Protocol Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Something();
  $arrayref_of_logical_chunks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
     $filter->put($arrayref_of_logical_chunks);

=head1 DESCRIPTION

Filters provide a generic interface for low and medium level
protocols.  Wheels use this interface to communicate in different
protocols without necessarily having to know the details for each.

In theory, filters should be interchangeable.  In practice, stream and
block protocols tend to be incompatible.

=head1 PUBLIC FILTER METHODS

These methods are the generic Filter interface.  Specific filters may
have additional methods.

=over 4

=item *

POE::Filter::new()

The new() method creates and initializes a new filter.  Specific
filters may have different constructor parameters.

=item *

POE::Filter::get($arrayref_of_raw_chunks_from_driver)

The get() method translates raw stream data into logical units.  It
accepts a reference to an array of raw stream chunks as returned from
POE::Driver::get().  It returns a reference to an array of complete
logical data chunks.  There may or may not be a 1:1 correspondence
between raw stream chunks and logical data chunks.

Some filters may buffer partial logical units until they are completed
in subsequent get() calls.

The get() method returns a reference to an empty array if the stream
doesn't include enough information for a complete logical unit.

=item *

POE::Filter::put($arrayref_of_logical_chunks)

The put() method takes a reference to an array of logical data chunks.
It serializes them into streamable representations suitable for
POE::Driver::put().  It returns the raw streamable versions in a
different array reference.

=item *

POE::Filter::get_pending()

The get_pending() method is part of wheels' buffer swapping mechanism.
It clears the filter's input buffer and returns a copy of whatever was
in it.  It doesn't manipulate filters' output buffers because they
don't exist (filters expect to receive entire logical data chunks from
sessions, so there's no reason to buffer data and frame it).

B<Please note that relying on the get_pending() method in networked
settings require some forethought.> For instance, POE::Filter::Stream
never buffers data.

Switching filters usually requires some sort of flow control,
otherwise it's easy to cause a race condition where one side sends the
wrong type of information for the other side's current filter.
Framing errors will ensue.  Consider the following:

Assume a server and client are using POE::Filter::Line.  When the
client asks the server to switch to POE::Filter::Reference, it should
wait for the server's ACK or NAK before changing its own filter.  This
lets the client avoid sending referenced data while the server still
is parsing lines.

Here's something else to consider.  Programs using POE::Wheel::put()
on TCP sockets cannot rely on each put data chunk arriving separately
on the receiving end of the connection.  This is because TCP coalesces
packets whenever possible, to minimize packet header overhead.

Most systems have a way to disable the TCP delay (Nagle's algorithm),
in one form or another.  If you need this, please check your C headers
for the TCP_NODELAY socket option.  It's neither portable, nor
supported in Perl by default.

The filterchange.perl sample program copes with flow control while
switching filters.

=back

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
