# $Id$

# Portable two-way pipe creation, trying as many different methods as
# we can.

package POE::Pipe::TwoWay;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Symbol qw(gensym);
use IO::Socket;
use POE::Pipe;

@POE::Pipe::TwoWay::ISA = qw( POE::Pipe );

sub DEBUG () { 0 }

sub new {
  my $type         = shift;
  my $conduit_type = shift;

  # Dummy object used to inherit the base POE::Pipe class.
  my $self = bless [], $type;

  # Generate symbols to be used as filehandles for the pipe's ends.
  my $a_read  = gensym();
  my $a_write = gensym();
  my $b_read  = gensym();
  my $b_write = gensym();

  if (defined $conduit_type) {
    ($a_read, $a_write, $b_read, $b_write) =
      $self->_try_type($conduit_type, $a_read, $a_write, $b_read, $b_write);
    return ($a_read, $a_write, $b_read, $b_write) if $a_read;
  }

  while (my $try_type = $self->get_next_preference()) {
    ($a_read, $a_write, $b_read, $b_write) =
      $self->_try_type($try_type, $a_read, $a_write, $b_read, $b_write);
    return ($a_read, $a_write, $b_read, $b_write) if $a_read;
    $self->shift_preference();
  }

  # There's nothing left to try.
  DEBUG and warn "nothing worked";
  return (undef, undef, undef, undef);
}

# Try a pipe by type.

sub _try_type {
  my ($self, $type, $a_read, $a_write, $b_read, $b_write) = @_;

  # Try a socketpair().
  if ($type eq "socketpair") {
    eval {
      socketpair($a_read, $b_read, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair 1 failed: $!";
    };

    # Socketpair failed.
    if (length $@) {
      warn "socketpair failed: $@" if DEBUG;
      return (undef, undef, undef, undef);
    }

    DEBUG and do {
      warn "using UNIX domain socketpairs";
      warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
    };

    # It's two-way, so each reader is also a writer.
    $a_write = $a_read;
    $b_write = $b_read;

    # Turn off buffering.  POE::Kernel does this for us, but someone
    # might want to use the pipe class elsewhere.
    select((select($a_write), $| = 1)[0]);
    select((select($b_write), $| = 1)[0]);
    return ($a_read, $a_write, $b_read, $b_write);
  }

  # Try a couple pipe() calls.
  if ($type eq "pipe") {
    eval {
      pipe($a_read, $b_write) or die "pipe 1 failed: $!";
      pipe($b_read, $a_write) or die "pipe 2 failed: $!";
    };

    # Pipe failed.
    if (length $@) {
      warn "pipe failed: $@" if DEBUG;
      return (undef, undef, undef, undef);
    }

    DEBUG and do {
      warn "using a pipe";
      warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
    };

    # Turn off buffering.  POE::Kernel does this for us, but someone
    # might want to use the pipe class elsewhere.
    select((select($a_write), $| = 1)[0]);
    select((select($b_write), $| = 1)[0]);
    return ($a_read, $a_write, $b_read, $b_write);
  }

  # Try a pair of plain INET sockets.
  if ($type eq "inet") {
    eval {
      ($a_read, $b_read) = $self->make_socket();
    };

    # Sockets failed.
    if (length $@) {
      warn "make_socket failed: $@" if DEBUG;
      return (undef, undef, undef, undef);
    }

    DEBUG and do {
      warn "using a plain INET socket";
      warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
    };

    $a_write = $a_read;
    $b_write = $b_read;

    # Turn off buffering.  POE::Kernel does this for us, but someone
    # might want to use the pipe class elsewhere.
    select((select($a_write), $| = 1)[0]);
    select((select($b_write), $| = 1)[0]);
    return ($a_read, $a_write, $b_read, $b_write);
  }

  DEBUG and warn "unknown OneWay socket type ``$type''";
  return;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Pipe::TwoWay - portable two-way pipe creation (works without POE)

=head1 SYNOPSIS

  my ($a_read, $a_write, $b_read, $b_write) = POE::Pipe::TwoWay->new();
  die "couldn't create a pipe: $!" unless defined $a_read;

=head1 DESCRIPTION

POE::Pipe::TwoWay makes unbuffered two-way pipes or it dies trying.
It can be more frugal with filehandles than two OneWay pipes when
socketpair() is available.

Pipes are troublesome beasts because the different pipe creation
methods have spotty support from one system to another.  Some systems
have C<pipe()>, others have C<socketfactory()>, and still others have
neither.

POE::Pipe::TwoWay tries different ways to make a pipe in the hope that
one of them will succeed on any given platform.  It tries them in
socketpair() -> pipe() -> IO::Socket::INET order.  If socketpair() is
available, the two-way pipe will use half as many filehandles as two
one-way pipes.

So anyway, the syntax is pretty easy:

  my ($a_read, $a_write, $b_read, $b_write) = POE::Pipe::TwoWay->new();
  die "couldn't create a pipe: $!" unless defined $a_read;

And now you have an unbuffered pipe with two read/write sides, A and
B.  Writing to C<$a_write> passes data to C<$b_read>, and writing to
C<$b_write> passes data to C<$a_read>.

=head1 DEBUGGING

It's possible to force POE::Pipe::TwoWay to use one of its underlying
pipe methods.  This was implemented for exercising each method in
tests, but it's possibly useful for others.

However, forcing TwoWay's pipe method isn't documented because it's
cheezy and likely to change.  Use it at your own risk.

=head1 BUGS

The INET domain socket method may block for up to 1s if it fails.

=head1 AUTHOR & COPYRIGHT

POE::Pipe::TwoWay is copyright 2000 by Rocco Caputo.  All rights
reserved.  POE::Pipe::TwoWay is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut
