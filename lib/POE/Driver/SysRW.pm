###############################################################################
# SysRW.pm - Documentation and Copyright are after __END__.
###############################################################################

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
  my ($self, $k, $handle) = @_;
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

Documentation: to be

Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
This is a pre-release version.  Redistribution and modification are
prohibited.
