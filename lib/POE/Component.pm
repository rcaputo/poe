# $Id$
# Copyrights and documentation are after __end__.

package POE::Component;

use strict;

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

1;

__END__

=head1 NAME

POE::Component - POE Stand-Alone Sessions

=head1 SYNOPSIS

Varies from component to component.

=head1 DESCRIPTION

POE components are sessions that have been designed as stand-alone
modules.  They tend to be interfaced through POE::Kernel::post() or
call(), but this is not a formal convention.

The POE::Component namespace was started to provide a place for others
publish their POE modules without requiring coordination with the main
POE distribution.

=head1 BUGS

The POE::Component namespace should probably be coordinated, but who
has time for that?

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage or manpages for specific components.

=cut
