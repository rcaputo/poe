# $Id$

package POE::Driver;

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

POE::Driver - POE Read/Write Abstraction

=head1 SYNOPSIS

  $driver = new POE::Driver::Something();
  $arrayref_of_data_chunks = $driver->get($filehandle);
  $queue_octets = $driver->put($arrayref_of_data_chunks);
  $queue_octets = $driver->flush($filehandle);
  $queue_messages = $driver->get_out_messages_buffered();

=head1 DESCRIPTION

Drivers provide a generic interface for low-level file I/O.  Wheels
use this interface to read and write files, sockets, and things,
without having to know the details for each.

In theory, drivers should be pretty much interchangeable.  In
practice, there seems to be an impermeable barrier between the
different SOCK_* types.

=head1 PUBLIC DRIVER METHODS

These methods are the generic Driver interface.  Specific drivers may
have additional methods.

=over 4

=item *

POE::Driver::new()

The new() method creates and initializes a new driver.  Specific
drivers may have different constructor parameters.

=item *

POE::Driver::get($filehandle)

The get() method immediately tries to read information from a
filehandle.  It returns a reference to an array of received data
chunks.  The array may be empty if nothing could be read.  The array
reference it returns is a suitable parameter to POE::Filter::get().

get() returns undef on an error.

Wheels usually call the get() method from their read select states.

=item *

POE::Driver::put($arrayref_of_data_chunks)

The put() method places raw data into the driver's output queue.  Some
drivers may flush data from the put() method.  It accepts a reference
to an array of writable chunks, and it returns the number of octets in
its output queue.

Wheels usually call the put() method from their own put() methods.

=item *

POE::Driver::flush($filehandle)

The flush() method attempts to flush some data from the driver's
output queue to the file.  It returns the number of octets remaining
in the output queue after the flush.

Wheels usually call the flush() method from their write select states.

=item *

POE::Driver::get_out_messages_buffered()

Returns the number of messages in the driver's output buffer.  If the
top message is partially flushed, it is still counted as a full one.

=back

=head1 SEE ALSO

POE::Driver::SysRW

=head1 BUGS

There is no POE::Driver::SendRecv

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
