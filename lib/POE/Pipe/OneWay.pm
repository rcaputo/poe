# $Id$

# Portable one-way pipe creation, trying as many different methods as
# we can.

package POE::Pipe::OneWay;

use strict;
use Symbol qw(gensym);
use IO::Socket;
use POE::Pipe;

@POE::Pipe::OneWay::ISA = qw( POE::Pipe );

sub DEBUG () { 0 }
sub RUNNING_IN_HELL () { $^O eq 'MSWin32' }

# This flag is set true/false after the first attempt at using plain
# INET sockets as pipes.
my $can_run_socket = undef;

sub new {
  my $type         = shift;
  my $conduit_type = shift;

  # Dummy object used to inherit the base POE::Pipe class.
  my $self = bless [], $type;

  # Generate symbols to be used as filehandles for the pipe's ends.
  my $a_read  = gensym();
  my $b_write = gensym();

  # Try the pipe if no preferred conduit type is specified, or if the
  # specified conduit type is 'pipe'.
  if ( (not RUNNING_IN_HELL) and
       ( (not defined $conduit_type) or
         ($conduit_type eq 'pipe')
       ) and
       ( not defined $can_run_socket )
     ) {

    eval {
      pipe($a_read, $b_write) or die "pipe failed: $!";
    };

    # Pipe succeeded.
    unless (length $@) {
      DEBUG and do {
        warn "using a pipe";
        warn "ar($a_read) bw($b_write)\n";
      };

      # Turn off buffering.  POE::Kernel does this for us, but
      # someone might want to use the pipe class elsewhere.
      select((select($b_write), $| = 1)[0]);
      return($a_read, $b_write);
    }
  }

  # Try UNIX-domain socketpair if no preferred conduit type is
  # specified, or if the specified conduit type is 'socketpair'.
  if ( (not RUNNING_IN_HELL) and
       ( (not defined $conduit_type) or
         ($conduit_type eq 'socketpair')
       ) and
       ( not defined $can_run_socket )
     ) {

    eval {
      socketpair($a_read, $b_write, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair failed: $!";
    };

    # Socketpair succeeded.
    unless (length $@) {
      DEBUG and do {
        warn "using a UNIX domain socketpair";
        warn "ar($a_read) bw($b_write)\n";
      };

      # It's one-way, so shut down the unused directions.
      shutdown($a_read,  1);
      shutdown($b_write, 0);

      # Turn off buffering.  POE::Kernel does this for us, but someone
      # might want to use the pipe class elsewhere.
      select((select($b_write), $| = 1)[0]);
      return($a_read, $b_write);
    }
  }

  # Try a pair of plain INET sockets if no preffered conduit type is
  # specified, or if the specified conduit type is 'inet'.
  if ( ( RUNNING_IN_HELL or
         (not defined $conduit_type) or
         ($conduit_type eq 'inet')
       ) and
       ( $can_run_socket or (not defined $can_run_socket) )
     ) {

    # Try using a pair of plain INET domain sockets.

    eval {
      ($a_read, $b_write) = $self->make_socket();
    };

    # Sockets worked.
    unless (length $@) {
      DEBUG and do {
        warn "using a plain INET socket";
        warn "ar($a_read) bw($b_write)\n";
      };

      # Try sockets more often.
      $can_run_socket = 1;

      # It's one-way, so shut down the unused directions.
      shutdown($a_read,  1);
      shutdown($b_write, 0);

      # Turn off buffering.  POE::Kernel does this for us, but someone
      # might want to use the pipe class elsewhere.
      select((select($b_write), $| = 1)[0]);
      return($a_read, $b_write);
    }

    # Sockets failed.  Don't dry them again.
    else {
      $can_run_socket = 0;
    }
  }

  # There's nothing left to try.
  DEBUG and warn "nothing worked";
  return(undef, undef);
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
