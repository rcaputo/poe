#!/usr/bin/perl 
# $Id$

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
    $error = "$^O does not support fork/exec properly";
  }
  if ($error) {
    print "1..0 # Skip $error\n";
    exit();
  }
}

use Test::More tests => 1;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw/Wheel::Run Session/;

tie *STDERR, 'Test::Tie::Handle';
POE::Session->create(
  inline_states => {
    _start => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];
      my $wheel = POE::Wheel::Run->new(
        Program     => [ 'sh', '-c', 'echo "My stderr" >/dev/stderr' ],
        StderrEvent => 'stderr'
      );
      $heap->{wheel} = $wheel;
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
    _stop => sub {
      ok( $_[HEAP]->{got_stderr}, "received STDERR despite it being tied");
    },
  },
);

$poe_kernel->run;

BEGIN {
  package Test::Tie::Handle;
  use Tie::Handle;
  use vars qw(@ISA);
  @ISA = 'Tie::Handle';

  sub TIEHANDLE {
    my $class = shift;
    my $fh    = do { \local *HANDLE};
    bless $fh,$class;
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
