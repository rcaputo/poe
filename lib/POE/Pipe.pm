# $Id$

# Common routines for POE::Pipe::OneWay and ::TwoWay.  This is meant
# to be inherited.  This is ugly, messy code right now.  It fails
# terribly upon the slightest error, which is generally bad.

package POE::Pipe;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Symbol qw(gensym);
use IO::Socket;
use POSIX qw(fcntl_h errno_h);

# Provide a dummy EINPROGRESS for systems that don't have one.  Give
# it a documented value.  This code is stolen from
# POE::Wheel::SocketFactory.

BEGIN {
  # http://support.microsoft.com/support/kb/articles/Q150/5/37.asp
  # defines EINPROGRESS as 10035.  We provide it here because some
  # Win32 users report POSIX::EINPROGRESS is not vendor-supported.
  if ($^O eq 'MSWin32') {
    eval '*EINPROGRESS = sub { 10036 };';
    eval '*EWOULDBLOCK = sub { 10035 };';
    eval '*F_GETFL     = sub {     0 };';
    eval '*F_SETFL     = sub {     0 };';
  }
}

# Static member.  Call like a regular function.  Turn off blocking on
# sockets created by make_socket.

sub _stop_blocking {
  my $socket_handle = shift;

  # RCC 2002-12-19: Replace the complex blocking checks and methods
  # with IO::Handle's blocking(0) method.  This is theoretically more
  # portable and less maintenance than rolling our own.  If things
  # work out, we'll replace this function entirely.

  # RCC 2003-01-20: Perl 5.005_03 doesn't like blocking(), so we'll
  # only call it in perl 5.8.0 and beyond.

  if ($] >= 5.008) {
    $socket_handle->blocking(0);
  }
  else {
    # Do it the Win32 way.  XXX This is incomplete.
    if ($^O eq 'MSWin32') {
      my $set_it = "1";

      # 126 is FIONBIO (some docs say 0x7F << 16)
      ioctl( $socket_handle,
             0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
             $set_it
           )
        or die "ioctl fails: $!";
    }

    # Do it the way everyone else does.
    else {
      my $flags = fcntl($socket_handle, F_GETFL, 0) or die "getfl fails: $!";
      $flags = fcntl($socket_handle, F_SETFL, $flags | O_NONBLOCK)
        or die "setfl fails: $!";
    }
  }
}

# Another static member.  Turn blocking on when we're done, in case
# someone wants blocking pipes for some reason.

sub _start_blocking {
  my $socket_handle = shift;

  # RCC 2002-12-19: Replace the complex blocking checks and methods
  # with IO::Handle's blocking(1) method.  This is theoretically more
  # portable and less maintenance than rolling our own.  If things
  # work out, we'll replace this function entirely.

  # RCC 2003-01-20: Perl 5.005_03 doesn't like blocking(), so we'll
  # only call it in perl 5.8.0 and beyond.

  if ($] >= 5.008) {
    $socket_handle->blocking(1);
  }
  else {
    # Do it the Win32 way.  XXX This is incomplete.
    if ($^O eq 'MSWin32') {
      my $unset_it = "0";

      # 126 is FIONBIO (some docs say 0x7F << 16)
      ioctl( $socket_handle,
             0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
             $unset_it
           )
        or die "ioctl fails: $!";
    }

    # Do it the way everyone else does.
    else {
      my $flags = fcntl($socket_handle, F_GETFL, 0) or die "getfl fails: $!";
      $flags = fcntl($socket_handle, F_SETFL, $flags & ~O_NONBLOCK)
        or die "setfl fails: $!";
    }
  }
}

# Make a socket.  This is a homebrew socketpair() for systems that
# don't support it.  The things I must do to make Windows happy.

sub make_socket {

  ### Server side.

  my $acceptor = gensym();
  my $accepted = gensym();

  my $tcp = getprotobyname('tcp') or die "getprotobyname: $!";
  socket( $acceptor, PF_INET, SOCK_STREAM, $tcp ) or die "socket: $!";

  setsockopt( $acceptor, SOL_SOCKET, SO_REUSEADDR, 1) or die "reuse: $!";

  my $server_addr = inet_aton('127.0.0.1') or die "inet_aton: $!";
  $server_addr = pack_sockaddr_in(0, $server_addr)
    or die "sockaddr_in: $!";

  bind( $acceptor, $server_addr ) or die "bind: $!";

  _stop_blocking($acceptor);

  $server_addr = getsockname($acceptor);

  listen( $acceptor, SOMAXCONN ) or die "listen: $!";

  ### Client side.

  my $connector = gensym();

  socket( $connector, PF_INET, SOCK_STREAM, $tcp ) or die "socket: $!";

  _stop_blocking($connector) unless $^O eq 'MSWin32';

  unless (connect( $connector, $server_addr )) {
    die "connect: $!" if $! and ($! != EINPROGRESS) and ($! != EWOULDBLOCK);
  }

  my $connector_address = getsockname($connector);
  my ($connector_port, $connector_addr) =
    unpack_sockaddr_in($connector_address);

  ### Loop around 'til it's all done.  I thought I was done writing
  ### select loops.  Damnit.

  my $in_read  = '';
  my $in_write = '';

  vec( $in_read,  fileno($acceptor),  1 ) = 1;
  vec( $in_write, fileno($connector), 1 ) = 1;

  my $done = 0;
  while ($done != 0x11) {
    my $hits = select( my $out_read   = $in_read,
                       my $out_write  = $in_write,
                       undef,
                       5
                     );
    unless ($hits) {
      next if ($! and ($! == EINPROGRESS) or ($! == EWOULDBLOCK));
      die "select: $!" unless $hits;
    }

    # Accept happened.
    if (vec($out_read, fileno($acceptor), 1)) {
      my $peer = accept($accepted, $acceptor);
      my ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);

      if ( $peer_port == $connector_port and
           $peer_addr eq $connector_addr
         ) {
        vec($in_read, fileno($acceptor), 1) = 0;
        $done |= 0x10;
      }
    }

    # Connect happened.
    if (vec($out_write, fileno($connector), 1)) {
      $! = unpack('i', getsockopt($connector, SOL_SOCKET, SO_ERROR));
      die "connect: $!" if $!;

      vec($in_write, fileno($connector), 1) = 0;
      $done |= 0x01;
    }
  }

  # Turn blocking back on, damnit.
  _start_blocking($accepted);
  _start_blocking($connector);

  return ($accepted, $connector);
}

1;

__END__

=head1 NAME

POE::Pipe - common functions for POE::Pipe::OneWay and ::TwoWay

=head1 SYNOPSIS

  None.

=head1 DESCRIPTION

POE::Pipe contains some helper functions to create a socketpair out of
discrete Internet sockets.  It's used by POE::Pipe::OneWay and
POE::Pipe::TwoWay as a last resort if pipe() and socketpair() fail.

=head1 BUGS

The functions implemented here die outright upon failure, requiring
eval{} around their calls.

=head1 AUTHOR & COPYRIGHT

POE::Pipe is copyright 2001 by Rocco Caputo.  All rights reserved.
POE::Pipe is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
