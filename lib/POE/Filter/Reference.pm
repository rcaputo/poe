# $Id$
# Documentation exists after __END__

package POE::Filter::Reference;

use strict;
use Storable qw(freeze thaw);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'framing buffer' => '' }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my $string .= join('', @$stream);
  my @return;
  
  my $data;
  my $i = 1;
  if(exists($self->{'pre_get'})) {
    $string =~s/\A(.{$self->{'pre_get'}})//s;
    my $ick = $self->{pre_got}.$1;
    push @return,thaw($ick);
    delete($self->{'pre_get'});
    delete($self->{'pre_got'});
  }
  while($string ne "") {
    die "LOOP EXISTS:" if($i++ == 500);
    $string =~s/\A(\d\d\d\d\d)//;
    my $bytes_to_get = $1;
    if(length($string) < $bytes_to_get) {
      $self->{'pre_get'} = $bytes_to_get - length($string);
      $bytes_to_get = length($string);
      $string =~s/\A(.{$bytes_to_get})//s;
      $self->{'pre_got'} = $1;
      last;
    } else {
      $string =~s/\A(.{$bytes_to_get})//s;
      my $data = $1;
      push @return,thaw($data);
    }
  }
  return \@return;
}

#------------------------------------------------------------------------------

sub put {
  my $self = shift;
  my $raw = join('', @_);
  $raw = freeze($raw);
  my $length = sprintf "%05d",length($raw);
  return length($raw).$raw;
}

###############################################################################
1;
__END__

=head1 NAME

POE::Filter::Reference - pass objects between references and streams

=head1 SYNOPSIS

  $ref_filter = new POE::Filter::Reference();

  $reference = { key => 'value' };
  $frozen_data = $ref_filter->put($refernece);

  @references = $ref_filter->get($frozen_data);
  print $reference->{key}."\n";

=head1 DESCRIPTION

Breaks up a stream into references, based on a /(\d{5})(.{$1})/s
format.  Takes a reference and turns it into a sendable string.  Works
with any kind of reference that Storable works with, it is a fairly
easy task to exchange Storable with something else.

=head1 PUBLIC METHODS

Please see C<POE::Filter> for explanations.

=head1 EXAMPLES

Please see tests/refserver.perl and tests/refclient.perl.

=head1 BUGS

Only works with references which data is up to 99999 bytes, this needs
to be fixed.

=head1 CONTACT AND COPYRIGHT

Filter::Reference is contributed by Artur Bergman.

Filter::Reference partial copyright 1998 Artur Bergman
E<lt>artur@vogon-solutions.comE<gt>.

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights
reserved.  This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
