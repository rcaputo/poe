# $Id$
# Documentation exists after __END__


package POE;

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

POE - the Perl Operating Environment

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 CLASSES

=over 4

=item POE::Kernel - main loop; select(2), signal, alarm, event services
=item POE::Session - state machine managed by C<POE::Kernel>

=item POE::Driver - abstract C<IO::Handle> driver
=item POE::Driver::SysRW - C<sysread> and C<syswrite> on an C<IO::Handle>

=item POE::Filter - abstract raw E<lt>-E<gt> cooked stream translator
=item POE::Filter::Line - break input into lines; add newlines to output

=item POE::Wheel - extend C<POE::Session> by adding or removing event handlers
=item POE::Wheel::ReadWrite - manage read/write states for a session
=item POE::Wheel::ListenAccept - handle incoming TCP socket connections
=item POE::Wheel::FollowTail - watch the end of a growing file

=back

=head1 EXAMPLES

Please see the tests directory that comes with the POE bundle.

=head1 BUGS

C<POE::Wheel> is in need of a new interface.  Expect
this part to change.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
