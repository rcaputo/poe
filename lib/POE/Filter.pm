# $Id$
# Documentation exists after __END__

package POE::Filter;

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

POE::Filter - convert between raw and cooked streams

=head1 SYNOPSIS

  $filter = new POE::Filter::Derivative();

=head1 DESCRIPTION

Derivatives of C<POE::Filter> provide standard IO cooking and
uncooking for their parent C<IO::Session>s.  For example,
C<POE::Filter::Line> breaks up input into newline-delimited chunks of
input, and it appends newlines to the ends of chunks being output.

=head1 PUBLIC METHODS

=over 4

=item new POE::Filter::Derivative

C<$filter = new POE::Filter::Derivative()>

Creates an instance of the given filter.

=item $filter->put(@chunks)

Returns a version of C<@chunks> that is formatted according to the
protocol that the filter implements.

=item $filter->get($chunk)

Returns a reference to an array of zero or more formatted pieces of
C<$chunk>.  Partial chunks are held inside C<POE::Filter> until they
are completed.

=back

=head1 EXAMPLES

Please see tests/selects.perl for an example of C<POE::Filter::Line>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights
reserved.  This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
