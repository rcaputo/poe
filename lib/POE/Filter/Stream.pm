# $Id$

package POE::Filter::Stream;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $t='';
  my $self = bless \$t, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my $buffer = join('', @$stream);
  [ $buffer ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  $chunks;
}

#------------------------------------------------------------------------------

sub get_pending {} #we don't keep any state

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Stream - POE Stream (Null) Protocol Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Stream();
  $arrayref_of_logical_chunks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
     $filter->put($arrayref_of_logical_chunks);

=head1 DESCRIPTION

This filter passes data through unchanged.  It is a "null" filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Line;
POE::Filter::Reference; POE::Filter::Stream

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
