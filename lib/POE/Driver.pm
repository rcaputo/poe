# $Id$
# Documentation exists after __END__

package POE::Driver;

my $VERSION = 1.0;

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

POE::Driver - perform IO on a filehandle

=head1 SYNOPSIS

  $driver = new POE::Driver::Derivative(); # create a derivative driver
  \@input_chunks = $driver->get($handle);  # get data from $handle
  $result = $driver->put($output_chunk);   # put data into an output buffer
  $result = $driver->flush($handle);       # flush output buffer to $handle

=head1 DESCRIPTION

Derivatives of C<POE::Driver> provide standard IO functions for their parent
C<IO::Session>s.  For example, C<POE::Driver::SysRW> provides basic C<sysread>
and C<syswrite>, with buffering and error checking.

=head1 PUBLIC METHODS

=over 4

=item new POE::Driver::Derivative

Creates and returns a reference to a new C<POE::Driver> derivative.

=item $driver->put($output)

Adds C<$output> to the driver's output buffer.  See C<$driver->flush(...)>
to find out what happens next.  Returns the amount of data in the driver's
output buffer after C<$output> has been added.

=item $driver->get($handle)

Extracts data from a filehandle.  On success, it returns a reference to an
array of extracted chunks of information.  On failure, it sets $! and returns
C<undef>.  Some drivers may absorb C<EAGAIN>.

=item $driver->flush($handle)

Attempts to write to C<$handle> a chunk of information buffered by
C<$driver->put(...)>.  On success, it returns the amount of data waiting
to be written.  On failure, it returns undef and sets $!.  Some drivers
may absorb C<EAGAIN>.

=back

=head1 EXAMPLES

Please see tests/selects.perl for an example of C<POE::Driver> derivatives.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
