# $Id$

package POE::Filter::Line;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $t='';
  my $self = bless \$t, $type;      # we now use a scalar ref -PG
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  $$self .= join('', @$stream);
  my @result;
  while ($$self =~ s/^([^\x0D\x0A]*)(\x0D\x0A?|\x0A\x0D?)//) {
    push(@result, $1);
  }
  \@result;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $lines) = @_;
  my @raw = map { $_ . "\x0D\x0A" } @$lines;
  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending 
{
    my($self)=@_;
    return unless $$self;
    my $ret=[$$self];
    $$self='';
    return $ret;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Line - POE Line Protocol Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Line();
  $arrayref_of_lines =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_lines);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($single_line);

=head1 DESCRIPTION

The Line filter translates streams to and from newline-separated
lines.  The lines it returns do not contain newlines.  Neither should
the lines given to it.

Incoming newlines are recognized with the regexp
C</(\x0D\x0A?|\x0A\x0D?)/>.  Incomplete lines are buffered until a
subsequent packet completes them.

Outgoing lines have the network newline attached to them:
C<"\x0D\x0A">.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Reference;
POE::Filter::Stream

=head1 BUGS

This filter's newlines are hard-coded.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
