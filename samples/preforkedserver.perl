#!perl -w -I..
# $Id$

die "read the comments";
# This is a skeleton of what I think a pre-forked server should look
# like.  It's untested and probably is broken.  I can't guarantee it
# won't forkbomb you into oblivion.

# If you can make it work, I'd like to include your version as a
# contributed test/sample program.

use strict;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line);
use Socket;

#------------------------------------------------------------------------------

package PreforkedServer;

sub new {
  my ($type, $kernel) = @_;
  my $self = bless { 'kernel' => $kernel }, $type;

  new POE::Session( $kernel, $self,
                    [qw(_start connection command error signal fork)]
                  );
  undef;
}

sub _start {
  my ($o, $k, $me, $from) = @_;

  $me->{'wheel'} = new POE::Wheel::SocketFactory
    ( $k,
      SocketDomain   => AF_INET,
      SocketType     => SOCK_STREAM,
      SocketProtocol => 'tcp',
      BindAddress    => INADDR_ANY,
      BindPort       => 8888,
      ListenQueue    => 5,
      SuccessState   => 'connection',
      FailureState   => 'error'
    );

  $k->sig('CHLD', 'child');
  $k->sig('INT', 'sigint');
  $me->{'children'} = {};
  $me->{'is a child'} = 0;

  foreach (1..5) {
    $k->yield('fork');
  }
}

sub _stop {
  my ($o, $k, $me, $from) = @_;
  kill -INT, keys(%{$me->{'children'}});
}

sub fork {
  my ($o, $k, $me, $from) = @_;
                                        # don't fork from a child
  return if ($me->{'is a child'});

  my $pid = fork();
  die "fork: $!" unless(defined($pid));
                                        # parent returns immediately
  if ($pid) {
    $me->{'children'}->{$pid} = 1;
    return;
  }
                                        # do any child init here
  $me->{'is a child'} = 1;
}

sub signal {
  my ($o, $k, $me, $from, $signal, $pid, $status) = @_;
  if ($signal eq 'CHLD') {
    if (delete $me->{'children'}->{$pid}) {
      $k->yield('fork');
    }
  }
  elsif ($signal eq 'INT') {
    delete $me->{'wheel'};
  }
}
                                        ##### THIS IS THE CHILD PART
sub connection {
  my ($o, $k, $me, $from, $socket, $peer_addr, $peer_port) = @_;
                                        # become a read/write thing
  $me->{'wheel'} = new POE::Wheel::ReadWrite
    ( $k, 
      Handle => $socket,
      Driver => new POE::Driver::SysRW,
      Filter => new POE::Filter::Line,
      InputState => 'command',
      ErrorState => 'error',
      FlushedState => 'flushed'
    );
}

sub command {
  my ($o, $k, $me, $from, $line) = @_;
  $me->{'wheel'}->put("Echo: $line");
}

sub error {
  my ($o, $k, $me, $from, $operation, $errnum, $errstr) = @_;
  warn "$operation error $errnum: $errstr\n";
}

sub flushed {
  my ($o, $k, $me, $from) = @_;
  delete $me->{'wheel'};
}

#------------------------------------------------------------------------------

my $kernel = new POE::Kernel;
new PreforkedServer($kernel);
$kernel->run();
exit;
