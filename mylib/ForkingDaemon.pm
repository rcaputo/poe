# vim: ts=2 sw=2 expandtab
use strict; use warnings;

# companion to t/90_regression/rt65460-forking.t

use POE::Filter::Reference;
use IO::Handle;
use POSIX;
use Carp;

my $debug = 0;

main();

# basically ripped off from SimpleDBI::SubProcess
sub main {
  # Autoflush to avoid weirdness
  $|++;

  # set binmode, thanks RT #43442
  binmode( STDIN );
  binmode( STDOUT );

  my $filter = POE::Filter::Reference->new();

  # Okay, now we listen for commands from our parent :)
  while ( sysread( STDIN, my $buffer = '', 1024 ) ) {
    # Feed the line into the filter
    my $data = $filter->get( [ $buffer ] );

    # Process each data structure
    foreach my $input ( @$data ) {
      # should be hashref with data
      if ( $input->{debug} ) {
        $debug = 1;
        # enable tracing/asserts
        eval "sub POE::Kernel::TRACE_DEFAULT () { 1 };sub POE::Kernel::ASSERT_DEFAULT () { 1 };";
        die $@ if $@;
      }      

      do_test( $input->{file}, $input->{timing}, $input->{forked}, $input->{type} );
      CORE::exit( 0 );
    }
  }
}

sub do_test {
  my ($file,$timing,$forked,$type) = @_;

  my $oldpid = $$;

  # hook into warnings/die
  my $handler = sub {
    my $l = $_[0];
    $l =~ s/(?:\r|\n)+$//;
    open my $fh, '>>', $file or die "Unable to open $file: $!";
    $fh->autoflush( 1 );
    print $fh "$l\n";
    close $fh;
    return;
  };
  $SIG{'__WARN__'} = $handler;
  $SIG{'__DIE__'} = $handler;

  # Load POE before daemonizing or after?
  if ( $timing eq 'before' ) {
    eval "use POE; use POE::Session;";
    die $@ if $@;
  }

  # Okay, we daemonize before running POE
  do_daemonize( $type );

  if ( $timing eq 'after' ) {
    eval "use POE; use POE::Session;";
    die $@ if $@;
  }

  # Now we inform our test harness the PID
  open my $fh, '>>', $file or die "Unable to open $file: $!";
  $fh->autoflush( 1 );
  print $fh "OLDPID $oldpid\n";
  print $fh "PID $$\n";

  # start POE and do the test!
  POE::Kernel->has_forked if $forked eq 'has_fork';
  start_poe();

  # POE finished running, inform our test harness
  print $fh "DONE\n";
  close $fh;
  return;
}

sub do_daemonize {
  my $type = shift;

  eval {
    if ( $type eq 'nsd' ) {
      nsd_daemonize();
    } elsif ( $type eq 'dd' ) {
      dd_daemonize();
    } elsif ( $type eq 'mxd' ) {
      mxd_daemonize();
    } else {
      die "Unknown daemonization method: $type";
    }
  };
  die $@ if $@;
  return;
}

sub start_poe {
  # start POE with a basic test to see if it handled the daemonization
  POE::Session->create(
    inline_states => {
      _start => sub {
        warn "STARTING TEST" if $debug;
        $POE::Kernel::poe_kernel->yield( "do_test" );
        return;
      },
      do_test => sub {
        warn "STARTING DELAY" if $debug;
        $POE::Kernel::poe_kernel->delay( "done" => 1 );
        return;
      },
      done => sub {
        warn "DONE WITH DELAY" if $debug;
        return;
      },
    },
  );

  POE::Kernel->run;

  return;
}

# the rest of the code in this file is
# ripped off from Net::Server::Daemonize v0.05 as it does single-fork
# Removed some unnecessary code like pidfile/uid/gid/chdir stuff

### routine to protect process during fork
sub safe_fork () {

  ### block signal for fork
  my $sigset = POSIX::SigSet->new(SIGINT);
  POSIX::sigprocmask(SIG_BLOCK, $sigset)
    or die "Can't block SIGINT for fork: [$!]\n";

  ### fork off a child
  my $pid = fork;
  unless( defined $pid ){
    die "Couldn't fork: [$!]\n";
  }

  ### make SIGINT kill us as it did before
  $SIG{INT} = 'DEFAULT';

  ### put back to normal
  POSIX::sigprocmask(SIG_UNBLOCK, $sigset)
    or die "Can't unblock SIGINT for fork: [$!]\n";

  return $pid;
}

### routine to completely dissociate from
### terminal process.
sub nsd_daemonize {
  my $pid = safe_fork();

  ### parent process should do the pid file and exit
  if( $pid ){

    $pid && CORE::exit(0);


  ### child process will continue on
  }else{
    ### close all input/output and separate
    ### from the parent process group
    open STDIN,  '</dev/null' or die "Can't open STDIN from /dev/null: [$!]\n";
    open STDOUT, '>/dev/null' or die "Can't open STDOUT to /dev/null: [$!]\n";
    open STDERR, '>&STDOUT'   or die "Can't open STDERR to STDOUT: [$!]\n";

    ### Turn process into session leader, and ensure no controlling terminal
    POSIX::setsid();

    return 1;
  }
}

# the rest of the code in this file is
# ripped off from Daemon::Daemonize v0.0052 as it does double-fork
# Removed some unnecessary code like pidfile/chdir stuff

sub _fork_or_die {
    my $pid = fork;
    confess "Unable to fork" unless defined $pid;
    return $pid;
}

sub superclose {
    my $from = shift || 0;

    my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );
    $openmax = 64 if ! defined( $openmax ) || $openmax < 0;

    return unless $from < $openmax;

    POSIX::close( $_ ) foreach ($from .. $openmax - 1);
}

sub dd_daemonize {
    my $close = 1;

    # Fork once to go into the background
    {
        if ( my $pid = _fork_or_die() ) {
            CORE::exit 0;
        }
    }

    # Create new session
    (POSIX::setsid)
        || confess "Cannot detach from controlling process";

    # Fork again to ensure that daemon never reacquires a control terminal
    _fork_or_die() && CORE::exit 0;

    # Clear the file creation mask
    umask 0;

    if ( $close eq 1 || $close eq '!std' ) {
        # Close any open file descriptors
        superclose( $close eq '!std' ? 3 : 0 );
    }

    if ( $close eq 1 || $close eq 'std' ) {
        # Re-open  STDIN, STDOUT, STDERR to /dev/null
        open( STDIN,  "+>/dev/null" ) or confess "Could not redirect STDIN to /dev/null";

        open( STDOUT, "+>&STDIN" ) or confess "Could not redirect STDOUT to /dev/null";

        open( STDERR, "+>&STDIN" ) or confess "Could not redirect STDERR to /dev/null";

        # Avoid 'stdin reopened for output' warning (taken from MooseX::Daemonize)
        local *_NIL;
        open( _NIL, '/dev/null' );
        <_NIL> if 0;
    }

    return 1;
}

# the rest of the code in this file is
# ripped off from MooseX::Daemonize::Core v0.12 as it does some weird things ;)
# Removed some unnecessary code like Moose stuff

sub daemon_fork {
  if (my $pid = fork) {
    CORE::exit( 0 );
  } else {
    # now in the daemon
    return;
  }
}

sub daemon_detach {
    (POSIX::setsid)  # set session id
        || confess "Cannot detach from controlling process";
    {
        $SIG{'HUP'} = 'IGNORE';
        fork && CORE::exit;
    }
    umask 0;        # clear the file creation mask

        # get the max numnber of possible file descriptors
        my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );
        $openmax = 64 if !defined($openmax) || $openmax < 0;

        # close them all
        POSIX::close($_) foreach (0 .. $openmax);

    # fixup STDIN ...

    open(STDIN, "+>/dev/null")
        or confess "Could not redirect STDOUT to /dev/null";

    # fixup STDOUT ...

        open(STDOUT, "+>&STDIN")
            or confess "Could not redirect STDOUT to /dev/null";

    # fixup STDERR ...

        open(STDERR, "+>&STDIN")
            or confess "Could not redirect STDERR to /dev/null";        ;

    # do a little house cleaning ...

    # Avoid 'stdin reopened for output'
    # warning with newer perls
    open( NULLFH, '/dev/null' );
    <NULLFH> if (0);

    # return success
    return 1;
}

sub mxd_daemonize {
  daemon_fork();
  daemon_detach();
}
