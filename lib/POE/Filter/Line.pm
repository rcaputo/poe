# $Id$
# Documentation exists after __END__

package POE::Filter::Line;

my $VERSION = 1.0;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'framing buffer' => '' }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  $self->{'framing buffer'} .= join('', @$stream);
  my @result;
  while (
         $self->{'framing buffer'} =~ s/^([^\x0D\x0A]*)(\x0D\x0A?|\x0A\x0D?)//
  ) {
    push(@result, $1);
  }
  \@result;
}

#------------------------------------------------------------------------------

sub put {
  my $self = shift;
  my $raw = join('', @_) . "\x0D\x0A";
}

###############################################################################
1;
__END__

=head1 NAME

POE::Filter::Line - convert between line- and stream-based IO

=head1 SYNOPSIS

  $line = new POE::Filter::Line();

  $line_with_crlf = $line->put("A line of text.");

  $lines = $line->get("One\x0DTwo\x0AThree\x0D\x0AFour\x0A\x0DFive");
  print join(':', @$lines), "\n";

=head1 DESCRIPTION

Breaks up a stream into lines, based on any permutation of CR/LF.  Appends
CR/LF to the ends of lines being sent.

=head1 PUBLIC METHODS

Please see C<POE::Filter> for explanations.

=head1 EXAMPLES

Please see tests/selects.perl for examples of C<POE::Filter::Line>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
