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
  my $a_write = gensym();
  my $b_read  = gensym();
  my $b_write = gensym();

  # Try UNIX-domain socketpair if no preferred conduit type is
  # specified, or if the specified conduit type is 'socketpair'.
  if ( (not RUNNING_IN_HELL) and
       ( (not defined $conduit_type) or
         ($conduit_type eq 'socketpair')
       ) and
       ( not defined $can_run_socket )
     ) {

    eval {
      socketpair($a_read, $b_read, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair 1 failed: $!";
    };

    # Socketpair succeeded.
    unless (length $@) {
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
      return($a_read, $a_write, $b_read, $b_write);
    }
    elsif (DEBUG) {
      warn "socketpair failed: $@";
    }
  }

  # Try the pipe if no preferred conduit type is specified, or if the
  # specified conduit type is 'pipe'.
  if ( (not RUNNING_IN_HELL) and
       ( (not defined $conduit_type) or
         ($conduit_type eq 'pipe')
       ) and
       ( not defined $can_run_socket )
     ) {

    eval {
      pipe($a_read, $b_write) or die "pipe 1 failed: $!";
      pipe($b_read, $a_write) or die "pipe 2 failed: $!";
    };

    # Pipe succeeded.
    unless (length $@) {
      DEBUG and do {
        warn "using a pipe";
        warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
      };

      # Turn off buffering.  POE::Kernel does this for us, but someone
      # might want to use the pipe class elsewhere.
      select((select($a_write), $| = 1)[0]);
      select((select($b_write), $| = 1)[0]);
      return($a_read, $a_write, $b_read, $b_write);
    }
    elsif (DEBUG) {
      warn "pipe failed: $@";
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
      ($a_read, $b_read) = $self->make_socket();
    };

    # Sockets worked.
    unless (length $@) {
      # Try sockets more often.
      $can_run_socket = 1;

      $a_write = $a_read;
      $b_write = $b_read;

      # Turn off buffering.  POE::Kernel does this for us, but someone
      # might want to use the pipe class elsewhere.
      select((select($a_write), $| = 1)[0]);
      select((select($b_write), $| = 1)[0]);

      DEBUG and do {
        warn "using a plain INET socket";
        warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
      };

      return($a_read, $a_write, $b_read, $b_write);
    }

    # Sockets failed.  Don't dry them again.
    else {
      DEBUG and warn "make_socket failed: $@";
      $can_run_socket = 0;
    }
  }

  # There's nothing left to try.
  DEBUG and warn "nothing worked";
  return(undef, undef, undef, undef);
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
