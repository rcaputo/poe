# $Id$

# Portable one-way pipe creation, trying as many different methods as
# we can.

package POE::Pipe::OneWay;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Symbol qw(gensym);
use IO::Socket;
use POE::Pipe;

@POE::Pipe::OneWay::ISA = qw( POE::Pipe );

sub DEBUG () { 0 }

sub new {
  my $type         = shift;
  my $conduit_type = shift;

  # Dummy object used to inherit the base POE::Pipe class.
  my $self = bless [], $type;

  # Generate symbols to be used as filehandles for the pipe's ends.
  my $a_read  = gensym();
  my $b_write = gensym();

  if (defined $conduit_type) {
    return ($a_read, $b_write)
      if $self->_try_type($conduit_type, \$a_read, \$b_write);
  }

  while (my $try_type = $self->get_next_preference()) {
    return ($a_read, $b_write)
      if $self->_try_type($try_type, \$a_read, \$b_write);
    $self->shift_preference();
  }

  # There's nothing left to try.
  DEBUG and warn "nothing worked";
  return;
}

# Try a pipe by type.

sub _try_type {
  my ($self, $type, $a_read, $b_write) = @_;

  # Try a pipe().
  if ($type eq "pipe") {
    eval {
      pipe($$a_read, $$b_write) or die "pipe failed: $!";
    };

    # Pipe failed.
    if (length $@) {
      warn "pipe failed: $@" if DEBUG;
      return;
    }

    DEBUG and do {
      warn "using a pipe";
      warn "ar($$a_read) bw($$b_write)\n";
    };

    # Turn off buffering.  POE::Kernel does this for us, but
    # someone might want to use the pipe class elsewhere.
    select((select($$b_write), $| = 1)[0]);
    return 1;
  }

  # Try a UNIX-domain socketpair.
  if ($type eq "socketpair") {
    eval {
      socketpair($$a_read, $$b_write, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair failed: $!";
    };

    if (length $@) {
      warn "socketpair failed: $@" if DEBUG;
      return;
    }

    DEBUG and do {
      warn "using a UNIX domain socketpair";
      warn "ar($$a_read) bw($$b_write)\n";
    };

    # It's one-way, so shut down the unused directions.
    shutdown($$a_read,  1);
    shutdown($$b_write, 0);

    # Turn off buffering.  POE::Kernel does this for us, but someone
    # might want to use the pipe class elsewhere.
    select((select($$b_write), $| = 1)[0]);
    return 1;
  }

  # Try a pair of plain INET sockets.
  if ($type eq "inet") {
    eval {
      ($$a_read, $$b_write) = $self->make_socket();
    };

    if (length $@) {
      warn "make_socket failed: $@" if DEBUG;
      return;
    }

    DEBUG and do {
      warn "using a plain INET socket";
      warn "ar($$a_read) bw($$b_write)\n";
    };

    # It's one-way, so shut down the unused directions.
    shutdown($$a_read,  1);
    shutdown($$b_write, 0);

    # Turn off buffering.  POE::Kernel does this for us, but someone
    # might want to use the pipe class elsewhere.
    select((select($$b_write), $| = 1)[0]);
    return 1;
  }

  # There's nothing left to try.
  DEBUG and warn "unknown OneWay socket type ``$type''";
  return;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Pipe::OneWay - portable one-way pipe creation (works without POE)

=head1 SYNOPSIS

  my ($read, $write) = POE::Pipe::OneWay->new();
  die "couldn't create a pipe: $!" unless defined $read;

=head1 DESCRIPTION

POE::Pipe::OneWay makes unbuffered one-way pipes or it dies trying.

Pipes are troublesome beasts because the different pipe creation
methods have spotty support from one system to another.  Some systems
have C<pipe()>, others have C<socketfactory()>, and still others have
neither.

POE::Pipe::OneWay tries different ways to make a pipe in the hope that
one of them will succeed on any given platform.  It tries them in
pipe() -> socketpair() -> IO::Socket::INET order.

So anyway, the syntax is pretty easy:

  my ($read, $write) = POE::Pipe::OneWay->new();
  die "couldn't create a pipe: $!" unless defined $read;

And now you have a pipe with a read side and a write side.

=head1 DEBUGGING

It's possible to force POE::Pipe::OneWay to use one of its underlying
pipe methods.  This was implemented for exercising each method in
tests, but it's possibly useful for others.

However, forcing OneWay's pipe method isn't documented because it's
cheezy and likely to change.  Use it at your own risk.

=head1 BUGS

The INET domain socket method may block for up to 1s if it fails.

=head1 AUTHOR & COPYRIGHT

POE::Pipe::OneWay is copyright 2000 by Rocco Caputo.  All rights
reserved.  POE::Pipe::OneWay is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut
