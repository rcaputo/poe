# $Id$
# Documentation exists after __END__

package POE::Driver::SysRW;

use strict;
use POSIX qw(EAGAIN);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'out queue'  => [ ],
                     'bytes done' => 0,
                     'bytes left' => 0,
                   }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub put {
  my $self = shift;
  my $unit = join('', @_);
  my $queue_length = push @{$self->{'out queue'}}, $unit;
  if ($queue_length == 1) {
    $self->{'bytes left'} = length($unit);
    $self->{'bytes done'} = 0;
  }
  $queue_length;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $handle) = @_;

  my $result = sysread($handle, my $buffer = '', 1024);
  if ($result || ($! == EAGAIN)) {
    $! = 0;
    [ $buffer ];
  }
  else {
    undef;
  }
}

#------------------------------------------------------------------------------

sub flush {
  my ($self, $handle) = @_;
                                        # syswrite it, like we're supposed to
  my $wrote_count = syswrite($handle,
                             $self->{'out queue'}->[0],
                             $self->{'bytes left'},
                             $self->{'bytes done'}
                            );

  if ($wrote_count || ($! == EAGAIN)) {
    $! = 0;
    $self->{'bytes done'} += $wrote_count;
    unless ($self->{'bytes left'} -= $wrote_count) {
      shift(@{$self->{'out queue'}});
      if (@{$self->{'out queue'}}) {
        $self->{'bytes done'} = 0;
        $self->{'bytes left'} = length($self->{'out queue'}->[0]);
      }
      else {
        $self->{'bytes done'} = $self->{'bytes left'} = 0;
      }
    }
  }

  scalar(@{$self->{'out queue'}});
}

###############################################################################
1;
__END__

=head1 NAME

POE::Driver::SysRW - boilerplate sysread and syswrite

=head1 SYNOPSIS

  $sysrw = new POE::Driver::SysRW();     # create the SysRW driver
  \@input_chunks = $sysrw->get($handle); # sysread from $handle
  $result = $sysrw->put($output_chunk);  # add chunk to output buffer
  $result = $sysrw->flush($handle);      # syswrite from output buffer

=head1 DESCRIPTION

Basic non-blocking sysread and syswrite with error checking and buffering that
is compatible with C<POE::Kernel>'s non-blocking C<select(2)> logic.  Ignores
C<EAGAIN>.

=head1 PUBLIC METHODS

Please see C<POE::Driver> for explanations.

=head1 EXAMPLES

Please see tests/selects.perl for examples of C<POE::Driver::SysRW>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
