# Make pipes in a portable way.
# $Id$

package TestPipe;
use strict;
use Symbol qw(gensym);
use IO::Socket;

sub DEBUG () { 0 }

sub new {
  my $type = shift;

  # Every one of these pipes has two ends, and the ends have read and
  # write handles.  These are bidirectional.
  my $a_read  = gensym();
  my $a_write = gensym();
  my $b_read  = gensym();
  my $b_write = gensym();

  # The order of ways we try to make pipes is dictated by testing need
  # rather than any sort of efficiency.  My OS/2 machine supports
  # pipes but not socketpair; my FreeBSD machine supports both.

  # Try socketpair in the UNIX domain.
  eval {
    die "socketpair failed" unless 
      socketpair($a_read, $b_read, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
    open($a_write, "+<&=" . fileno($a_read)) or die "dup failed";
    open($b_write, "+<&=" . fileno($b_read)) or die "dup failed";
  };

  unless (length $@) {
    DEBUG and warn "using UNIX socketpair\n";
    return($a_read, $a_write, $b_read, $b_write);
  }

  # Try socketpair in the INET domain.
  eval {
    my $tcp_proto = getprotobyname('tcp') or die "getprotobyname failed";
    die "socketpair failed" unless
      socketpair($a_read, $b_read, AF_INET, SOCK_STREAM, $tcp_proto);
    open($a_write, "+<&=" . fileno($a_read)) or die "dup failed";
    open($b_write, "+<&=" . fileno($b_read)) or die "dup failed";
  };

  unless (length $@) {
    DEBUG and warn "using INET socketpair\n";
    return($a_read, $a_write, $b_read, $b_write);
  }

  # Try a pair of pipes.  Avoid doing this on systems that don't
  # support non-blocking pipes.
  if ($^O ne 'MSWin32') {
    eval {
      pipe($a_read, $b_write) or die "pipe failed";
      pipe($b_read, $a_write) or die "pipe failed";
    };

    unless (length $@) {
      DEBUG and warn "using a pair of pipes\n";
      return($a_read, $a_write, $b_read, $b_write);
    }
  }

  # Try traditional INET domain sockets.
  my $old_sig_alarm = $SIG{ALRM};
  eval {
    local $SIG{ALRM} = sub { die "deadlock" };
    alarm(5);

    my $acceptor = IO::Socket::INET->new
      ( LocalAddr => '127.0.0.1',
        LocalPort => 31415,
        Listen    => 5,
        Reuse     => 'yes',
      );

    $a_read = IO::Socket::INET->new
      ( PeerAddr  => '127.0.0.1',
        PeerPort  => 31415,
        Reuse     => 'yes',
      );

    $b_read = $acceptor->accept() or die "accept";

    open($a_write, "+<&=" . fileno($a_read)) or die "dup failed";
    open($b_write, "+<&=" . fileno($b_read)) or die "dup failed";
  };
  alarm(0);
  $SIG{ALRM} = $old_sig_alarm;

  unless (length $@) {
    DEBUG and warn "using a plain INET socket";
    return($a_read, $a_write, $b_read, $b_write);
  }

  # There's nothing left to try.
  return(undef, undef, undef, undef);
}

1;
