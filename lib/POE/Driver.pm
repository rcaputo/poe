# $Id$

package POE::Driver;

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

POE::Driver - an abstract file driver

=head1 SYNOPSIS

  $driver = new POE::Driver::Something();
  $arrayref_of_data_chunks = $driver->get($filehandle);
  $queue_octets = $driver->put($arrayref_of_data_chunks);
  $queue_octets = $driver->flush($filehandle);
  $queue_messages = $driver->get_out_messages_buffered();

=head1 DESCRIPTION

Drivers implement generic interfaces to low-level file I/O.  Wheels
use them to read and write files, sockets, and other things without
needing to know the details for doing so.

=head1 PUBLIC DRIVER METHODS

These methods are the generic Driver interface, and every driver must
implement them.  Specific drivers may have additional methods.

=over 4

=item new

new() creates and initializes a new driver.  Specific drivers may have
different constructor parameters.

=item get FILEHANDLE

get() immediately tries to read information from a filehandle.  It
returns a reference to an array containing whatever it managed to
read, or an empty array if nothing could be read.  It returns undef on
error, and $! will be set.

The arrayref get() returns is suitable for passing to any
POE::Filter's get() method.  This is exactly what the ReadWrite wheel
does with it.

=item put ARRAYREF

put() places raw data chunks into the driver's output queue.  it
accepts a reference to a list of raw data chunks, and it returns the
number of octets remaining in its output queue.

Some drivers may flush data immediately from their put() methods.

=item flush FILEHANDLE

flush() attempts to flush some data from the driver's output queue to
the FILEHANDLE.  It returns the number of octets remaining in the
output queue after the flush attempt.

=item get_out_messages_buffered

This data accessor returns the number of messages in the driver's
output queue.  Partial messages are counted as whole ones.

=back

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

There is no POE::Driver::SendRecv, but nobody has needed one so far.

In theory, drivers should be pretty much interchangeable.  In
practice, there seems to be an impermeable barrier between the
different SOCK_* types.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
