# $Id$

package POE::Filter::Stream;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $buffer = '';
  my $self = bless \$buffer, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my $buffer = join('', @$stream);
  [ $buffer ];
}

#------------------------------------------------------------------------------
# 2001-07-27 RCC: The get_one() variant of get() allows Wheel::Xyz to
# retrieve one filtered block at a time.  This is necessary for filter
# changing and proper input flow control.  Although it's kind of
# pointless for Stream, but it has to follow the proper interface.

sub get_one_start {
  my ($self, $stream) = @_;
  $$self .= join '', @$stream;
}

sub get_one {
  my $self = shift;
  return [ ] unless length $$self;
  my $chunk = $$self;
  $$self = '';
  return [ $chunk ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  [ @$chunks ];
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  return [ $$self ] if length $$self;
  return undef;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Stream - pass through data unchanged (a do-nothing filter)

=head1 SYNOPSIS

  $filter = POE::Filter::Stream->new();
  $arrayref_of_logical_chunks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
     $filter->put($arrayref_of_logical_chunks);

=head1 DESCRIPTION

This filter passes data through unchanged.

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
