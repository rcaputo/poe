# $Id$
# Documentation exists after __END__

package POE::Filter::Reference;

use strict;

BEGIN {
  eval {
    require Storable;
    import Storable qw(freeze thaw);
  };
  if ($@ ne '') {
    eval {
      require FreezeThaw;
      import FreezeThaw qw(freeze thaw);
    };
  }
  if ($@ ne '') {
    die "Filter::Reference requires Storable or FreezeThaw";
  }
}

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
    $string =~s/\A(\d+)\0//;
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
# freeze one or more references, and return a string representing them

sub put {
  my $self = shift;
  my $return = '';
  foreach my $raw (@_) {
    my $frozen = freeze($raw);
    $return .= length($frozen) . "\0" . $frozen;
  }
  $return;
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

Breaks up a stream into references, based on a /(\d+)\0(.{$1})/s
format.  Takes a reference and turns it into a sendable string.  Works
with any kind of reference that Storable works with, it is a fairly
easy task to exchange Storable with something else.

=head1 PUBLIC METHODS

Please see C<POE::Filter> for explanations.

=item C<put()>

Accepts one or more references, freezes them, and returns a string
suitable for streaming.

=item C<get()>

Accepts a block of streamed data.  Breaks it into zero or more frozen
objects, thaws them, and returns references to them.

=head1 EXAMPLES

Please see tests/refserver.perl and tests/refsender.perl.

=head1 BUGS

None currently known.

=head1 CONTACT AND COPYRIGHT

Filter::Reference is contributed by Artur Bergman.

Filter::Reference partial copyright 1998 Artur Bergman
E<lt>artur@vogon-solutions.comE<gt>.

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights
reserved.  This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
