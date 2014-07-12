# Deprecation notice: Read the documentation.

package POE::Pipe;

use warnings;
use strict;

use vars qw($VERSION);
$VERSION = '1.362'; # NOTE - Should be #.### (three decimal places)

use IO::Pipely;

1;

__END__

=head1 NAME

POE::Pipe - Deprecated and replaced with delegates to IO::Pipely.

=head1 SYNOPSIS

See L<IO::Pipely>.

=head1 DESCRIPTION

On June 29, 2012, POE::Pipe and its subclasses, POE::Pipe::OneWay and
POE::Pipe::TwoWay were released to CPAN as IO::Pipely.  The POE::Pipe
family of modules remained unchanged in POE's distribution.

On August 18, 2013, POE::Pipe and its subclasses were gutted.  Their
implementations were replaced with delegates to IO::Pipely.  All tests
pass, although the delegates add slight overhead.  The documentation
was replaced by this deprecation schedule.

A mandatory deprecation warning is scheduled to be released after
September 2014.  POE will begin using IO::Pipely directly.  This
documentation will be updated to schedule the next deprecation step.

The mandatory warning will become a mandatory error a year or so
later.  Ideally this will occur in August 2015, but it may be delayed
due to POE's release schedule.  This documentation will be updated to
schedule the final deprecation step.

Finally, in August 2016 or later, POE::Pipe and its subclasses will be
removed from POE's distribution altogether.  Users will have had at
least four years to update their code.  That seems fair.

=head1 SEE ALSO

L<IO::Pipely>

=head1 AUTHOR & COPYRIGHT

The POE::Pipe is copyright 2001-2013 by Rocco Caputo.  All rights
reserved.  POE::Pipe is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
