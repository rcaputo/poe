# $Id$
# Documentation exists after __END__

package POE;

$VERSION = "0.05";

use strict;
use Carp;

sub import {
  my $self = shift;
  my @modules = grep(!/^(Kernel|Session)$/, @_);
  unshift @modules, qw(Kernel Session);

  my @failed;
  foreach my $module (@modules) {
    eval("local $SIG{'__DIE__'} = 'DEFAULT'; require POE::" . $module)
      or push(@failed, $module);
  }

  @failed and croak "could not import qw(" . join(' ', @failed) . ")";
}

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

use POE;

=head1 DESCRIPTION

In general, POE provides "kernel" services, including C<select(2)>, events
signals, alarms and reusable boilerplates for common functions.

In specific, POE uses C<POE::Kernel> and C<POE::Session> for you.

=head1 CLASSES

=over 4

=item * POE::Kernel - main loop; select(2), signal, alarm, event services

=item * POE::Session - state machine managed by C<POE::Kernel>

=item * POE::Driver (abstract) - drive (read and write) an C<IO::Handle>

=item * POE::Driver::SysRW - C<sysread> and C<syswrite> on an C<IO::Handle>

=item * POE::Filter (abstract) - bidirectional stream cooker; converts raw
data to something useful (such as lines), and back

=item * POE::Filter::Line - break input into lines; add newlines to output

=item * POE::Filter::Reference - freeze references; thaw streams

=item * POE::Wheel (abstract) - a way to extend C<POE::Session> by adding or
removing event handlers from state machines

=item * POE::Wheel::ReadWrite - manage read/write states for a session

=item * POE::Wheel::ListenAccept - accept incoming TCP socket connections

=item * POE::Wheel::FollowTail - watch the end of an ever-growing file

=back

=head1 EXAMPLES

=over

=item * F<tests/followtail.perl>

Starts 21 sessions, and runs them until SIGINT.  10 sessions write to dummy
log files; 10 sessions follow the log tails; one session spins its wheels to
make sure things are not blocking.

=item * F<tests/forkbomb.perl>

Starts one session whose job is to continually start copies of itself (and
occasionally quit).  A counter limits this test to about 150 total sessions,
and the kernel will respond to SIGINT by killing everything and exiting.

This is an excellent shakedown of parent/child relationships and signals.

=item * F<tests/objsessions.perl>

This is a version of F<tests/sessions.perl> (see below) that uses a
blessed object's methods as event handlers.  Thanks to sky_GOD for the
idea and original code.

=item * F<tests/proxy.perl>

This is a simple line-based TCP proxy.  It redirects connections from
localhost:7777 to perl.com:echo.  It shows how to use two or more wheels
from a single session.

-item * F<tests/refserver.perl>

Accepts frozen objects from other programs, thaws them, and displays
information about them.

=item * F<tests/refsender.perl>

Freezes referenced data, and sends it to a waiting refserver.perl.

=item * F<tests/selects.perl>

Starts two sessions, and runs until SIGINT.  The first session is a TCP chargen
server; the second is a simple TCP client that connects to the first.  The
client session has a limiter that causes the session to exit after printing a
few chargen lines.

C<POE::Wheel::ReadWrite> and C<POE::Wheel::ListenAccept> were based on the code
here.

This was the second test, written to exercise the C<select(2)> logic in
C<POE::Kernel>.

=item * F<tests/sessions.perl>

Starts five sessions that loop a few times and stop.  It was written to
exercise the C<POE::Kernel> event queue.

=item * F<tests/signals.perl>

One session that prints out a dot every second and recognizes SIGINT.

=item * F<tests/curator.perl>

Lame attempt to exercise C<POE::Curator>.

=back

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights
reserved.  This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

Portions may also be copyrighted by their respective contributors.

=cut
