# $Id$

package POE::Filter::Block;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;

  my $self = { blocksize      => abs(shift) || 512,
               framing_buffer => ''
             };

  bless $self, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;

  $self->{framing_buffer} .= join '', @{$stream};

  my @blocks;
  while (length $self->{framing_buffer} >= $self->{blocksize}) {
    push @blocks, substr($self->{framing_buffer}, 0, $self->{blocksize}, "");
  }

  \@blocks;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $blocks) = @_;
  my @raw = join '', @{$blocks};
  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  return unless $self->{framing_buffer};
  [ $self->{framing_buffer ];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Block - POE Block Protocol Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Block(1024);
  $arrayref_of_blocks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_blocks);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($single_block);
  $arrayref_of_leftovers =
    $filter->get_pending();

=head1 DESCRIPTION

The Block filter translates streams to and from blocks of bytes of a
specified size.  If the size is not specified, 512 is used as default;
if the given size is negative, the absolute value is used instead.
Anyway, people trying to use negative blocksizes should be soundly
spanked.

Extra bytes are buffered until more bytes arrive to complete a block.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Reference;
POE::Filter::Stream; POE::Filter::Line

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
