#!/usr/bin/perl 
# vim: filetype=perl

# Scott Beck reported that tied STDERR breaks POE::Wheel::Run.  He
# suggested untying STDOUT and STDERR in the child process.  This test
# makes sure the bad behavior does not come back.

use strict;

# Skip these tests if fork() is unavailable.
BEGIN {
  my $error;
  if ($^O eq "MacOS") {
    $error = "$^O does not support fork";
  }
  elsif ($^O eq "MSWin32") {
    eval "use Win32::Console";
    if ($@) {
      $error = "Win32::Console is required on $^O - try ActivePerl";
    }
    else {
      $error = "$^O does not support fork/exec properly";
    }
  }
  if ($error) {
    print "1..0 # Skip $error\n";
    exit();
  }
}

sub DEBUG () { 0 }

use Test::More tests => 1;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw/Wheel::Run Session/;

tie *STDERR, 'Test::Tie::Handle';
POE::Session->create(
  inline_states => {
    _start => sub {
      my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

      $_[KERNEL]->sig( 'CHLD', 'sigchld' );
      $_[KERNEL]->refcount_increment( $session->ID, "teapot" );
      DEBUG and diag( "Installing CHLD signal Handler" );
      my $wheel = POE::Wheel::Run->new(
        Program     => [ $^X, '-e', 'warn "OK"' ],
        StderrEvent => 'stderr'
      );
      $heap->{wheel} = $wheel;
      $heap->{pid} = $wheel->PID;
      $kernel->delay(shutdown => 3);
      $heap->{got_stderr} = 0;
    },
    stderr => sub {
      delete $_[HEAP]->{wheel};
      $_[HEAP]->{got_stderr}++;
      $_[KERNEL]->delay(shutdown => undef);
    },
    shutdown => sub {
      delete $_[HEAP]->{wheel};
    },
    sigchld => sub {
      DEBUG and diag( "Got SIGCHLD for PID $_[ARG1]" );
      if ($_[ARG1] == $_[HEAP]->{pid}) {
        DEBUG and diag( "PID Matches, removing CHLD handler" );
        $_[KERNEL]->sig( 'CHLD' );
        $_[KERNEL]->refcount_decrement( $_[SESSION]->ID, "teapot" );
      }
    },
    _stop => sub {
      ok($_[HEAP]->{got_stderr}, "should receive STDERR even when tied");
    },
  },
);

$poe_kernel->run;

BEGIN {
  package Test::Tie::Handle;
  use Tie::Handle;
  use vars qw(@ISA);
  @ISA = 'Tie::Handle';
  use Symbol qw(gensym);

  sub TIEHANDLE {
    my $class = shift;
    my $fh    = gensym();
    bless $fh, $class;
    $fh->OPEN(@_) if (@_);
    return $fh;
  }

  sub EOF     { eof($_[0]) }
  sub TELL    { tell($_[0]) }
  sub FILENO  { fileno($_[0]) }
  sub SEEK    { seek($_[0],$_[1],$_[2]) }
  sub CLOSE   { close($_[0]) }
  sub BINMODE { binmode($_[0]) }

  sub OPEN {
    $_[0]->CLOSE if defined($_[0]->FILENO);
    open(@_);
  }

  sub READ     { read($_[0],$_[1],$_[2]) }
  sub READLINE { my $fh = $_[0]; <$fh> }
  sub GETC     { getc($_[0]) }

  my $out;
  sub WRITE {
    my $fh = $_[0];
    $out .= substr($_[1],0,$_[2]);
  }
}
