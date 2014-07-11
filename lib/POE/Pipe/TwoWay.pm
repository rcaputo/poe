# Deprecation notice: Read POE::Pipe's documentation.

package POE::Pipe::TwoWay;

use warnings;
use strict;

use base qw( POE::Pipe );

use vars qw($VERSION);
$VERSION = '1.361'; # NOTE - Should be #.### (three decimal places)

use IO::Pipely qw(socketpairly);

sub new {
  my ($class, $conduit_type) = @_;

  return socketpairly(
    debug => 0,
    type => $conduit_type,
  );
}

1;

__END__

=head1 NAME

POE::Pipe::TwoWay - Deprecated and replaced with delegates to IO::Pipely.

=head1 SYNOPSIS

See L<POE::Pipe> and L<IO::Pipely>.

=head1 DESCRIPTION

This module is deprecated.  L<IO::Pipely> was released to CPAN as its
replacement.  Please see L<POE::Pipe> for details, including the
deprecation schedule.

=head1 SEE ALSO

L<POE::Pipe> and L<IO::Pipely>.

=head1 AUTHOR & COPYRIGHT

POE::Pipe::TwoWay is copyright 2001-2013 by Rocco Caputo.  All rights
reserved.  POE::Pipe::TwoWay is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
