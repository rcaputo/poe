# $Id$
# Copyrights and documentation are after __end__.

package POE::Component;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(croak);

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

1;

__END__

=head1 NAME

POE::Component - a POE servlet class

=head1 SYNOPSIS

Varies from component to component.

=head1 DESCRIPTION

POE components are event-driven modules, many of which act as little
daemons that supply services to the programs they're parts of.  In
general, they talk with other sessions by receiving and posting
events, but this is not a formal convention.  A component's interface
design should prefer to make sense; for example, an SMTP client should
have a method to just "send a message" rather than (or in addition to)
several others that deal with the intricacies of the SMTP protocol.

The POE::Component namespace was started as place for contributors to
publish their POE-based modules without requiring coordination with
the main POE distribution.

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 TO DO

Document the customary (but not mandatory!) process of creating and
publishing a component.

=head1 AUTHORS & COPYRIGHTS

Each component is written and copyrighted by its author.

Please see L<POE> for more information about authors and contributors.

=cut
