###############################################################################
# SysRW.pm - Documentation and Copyright are after __END__.
###############################################################################

package POE::Filter::Line;

use strict;

###############################################################################

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

Documentation: to be

Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
This is a pre-release version.  Redistribution and modification are
prohibited.
