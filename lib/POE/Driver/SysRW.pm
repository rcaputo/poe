# $Id$

# Copyright 1998 Rocco Caputo <rcaputo@cpan.org>.  All rights
# reserved.  This program is free software; you can redistribute it
# and/or modify it under the same terms as Perl itself.

package POE::Driver::SysRW;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use POSIX qw(EAGAIN);
use Carp qw(croak);

sub OUTPUT_QUEUE        () { 0 }
sub CURRENT_OCTETS_DONE () { 1 }
sub CURRENT_OCTETS_LEFT () { 2 }
sub BLOCK_SIZE          () { 3 }
sub TOTAL_OCTETS_LEFT   () { 4 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless [ [ ], # OUTPUT_QUEUE
                     0,   # CURRENT_OCTETS_DONE
                     0,   # CURRENT_OCTETS_LEFT
                     512, # BLOCK_SIZE
                     0,   # TOTAL_OCTETS_LEFT
                   ], $type;

  if (@_) {
    if (@_ % 2) {
      croak "$type requires an even number of parameters, if any";
    }
    my %args = @_;
    if (defined $args{BlockSize}) {
      $self->[BLOCK_SIZE] = delete $args{BlockSize};
      croak "$type BlockSize must be greater than 0"
        if ($self->[BLOCK_SIZE]<1);
    }
    if (keys %args) {
      my @bad_args = sort keys %args;
      croak "$type has unknown parameter(s): @bad_args";
    }
  }

  $self;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  my $old_queue_octets = $self->[TOTAL_OCTETS_LEFT];

  foreach (grep { length } @$chunks) {
    $self->[TOTAL_OCTETS_LEFT] += length;
    push @{$self->[OUTPUT_QUEUE]}, $_;
  }

  if ($self->[TOTAL_OCTETS_LEFT] && (!$old_queue_octets)) {
    $self->[CURRENT_OCTETS_LEFT] = length($self->[OUTPUT_QUEUE]->[0]);
    $self->[CURRENT_OCTETS_DONE] = 0;
  }

  $self->[TOTAL_OCTETS_LEFT];
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $handle) = @_;

  my $result = sysread($handle, my $buffer = '', $self->[BLOCK_SIZE]);

  # sysread() was sucessful.  Return whatever was read.
  return [ $buffer ] if $result;

  # 18:01 <dngor> sysread() clears $! when it returns 0 for eof?
  # 18:01 <merlyn> nobody clears $!
  # 18:01 <merlyn> returning 0 is not an error
  # 18:01 <merlyn> returning -1 is an error, and sets $!
  # 18:01 <merlyn> eof is not an error. :)

  # 18:21 <dngor> perl -wle '$!=1; warn "\$!=",$!+0; \
  #               warn "sysread=",sysread(STDIN,my $x="",100); \
  #               die "\$!=",$!+0' < /dev/null
  # 18:23 <lathos> $!=1 at foo line 1.
  # 18:23 <lathos> sysread=0 at foo line 1.
  # 18:23 <lathos> $!=0 at foo line 1.
  # 18:23 <lathos> 5.6.0 on Darwin.
  # 18:23 <dngor> Same, 5.6.1 on fbsd 4.4-stable.
  #               read(2) must be clearing errno or something.

  # sysread() returned 0, signifying EOF.  Although $! is magically
  # set to 0 on EOF, it may not be portable to rely on this.
  if (defined $result) {
    $! = 0;
    return undef;
  }

  # Nonfatal sysread() error.  Return an empty list.
  return [ ] if $! == EAGAIN;

  # fatal sysread error
  undef;
}

#------------------------------------------------------------------------------

sub flush {
  my ($self, $handle) = @_;
                                        # syswrite it, like we're supposed to
  while (@{$self->[OUTPUT_QUEUE]}) {
    my $wrote_count = syswrite($handle,
                               $self->[OUTPUT_QUEUE]->[0],
                               $self->[CURRENT_OCTETS_LEFT],
                               $self->[CURRENT_OCTETS_DONE],
                              );

    unless ($wrote_count) {
      $! = 0 if ($! == EAGAIN);
      last;
    }

    $self->[CURRENT_OCTETS_DONE] += $wrote_count;
    $self->[TOTAL_OCTETS_LEFT] -= $wrote_count;
    unless ($self->[CURRENT_OCTETS_LEFT] -= $wrote_count) {
      shift(@{$self->[OUTPUT_QUEUE]});
      if (@{$self->[OUTPUT_QUEUE]}) {
        $self->[CURRENT_OCTETS_DONE] = 0;
        $self->[CURRENT_OCTETS_LEFT] = length($self->[OUTPUT_QUEUE]->[0]);
      }
      else {
        $self->[CURRENT_OCTETS_DONE] = $self->[CURRENT_OCTETS_LEFT] = 0;
      }
    }
  }

  $self->[TOTAL_OCTETS_LEFT];
}

#------------------------------------------------------------------------------

sub get_out_messages_buffered {
  scalar(@{$_[0]->[OUTPUT_QUEUE]});
}

###############################################################################
1;

__END__

=head1 NAME

POE::Driver::SysRW - an abstract sysread/syswrite file driver

=head1 SYNOPSIS

  $driver = POE::Driver::SysRW->new();
  $arrayref_of_data_chunks = $driver->get($filehandle);
  $queue_octets = $driver->put($arrayref_of_data_chunks);
  $queue_octets = $driver->flush($filehandle);
  $queue_messages = $driver->get_out_messages_buffered();

=head1 DESCRIPTION

This driver implements an abstract interface to sysread and syswrite.

=head1 PUBLIC METHODS

=over 2

=item new BlockSize => $block_size

=item new

new() creates a new SysRW driver.  It accepts one optional named
parameter, BlockSize, which tells it how much information to read and
write at a time.  BlockSize defaults to 512 if it's omitted.

  my $driver = POE::Driver::SysRW->new( BlockSize => $block_size );

  my $driver = POE::Driver::SysRW->new;

=back

=head1 SEE ALSO

POE::Driver.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
