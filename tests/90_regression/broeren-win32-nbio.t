#!/usr/bin/perl -w
# vim: filetype=perl

use strict;

use POE;
use Test::More;

if ($^O ne "MSWin32") {
  plan skip_all => "This test examines ActiveState Perl behavior.";
}

plan tests => 2;

my $obj = new MyDebug;

POE::Session->create(
  object_states => [ $obj => [ '_start', 'next', 'reaper', 'output' ] ]
);
POE::Kernel->run;

exit(0);

# ------------------------------------------------
# Now define our class which does all of the work.
# ------------------------------------------------

package MyDebug;

use strict;

use POE;
use POE::Wheel::Run;
use Test::More;

# Just adding POE::Wheel::SocketFactory breaks the program, the child
# will die prematurely
use POE::Wheel::SocketFactory;

use IO::Handle;
use File::Spec;
use POSIX qw(dup);

sub new {
  my $class = shift;
  return bless {};
}

sub _start {
  my ($self, $heap, $kernel) = @_[OBJECT, HEAP, KERNEL];
  $kernel->sig(CHLD => 'reaper');
  $self->{subprocess} = POE::Wheel::Run->new(
    Program => sub {
      my $buffer = "";
      my $input_stream  = IO::Handle::->new_from_fd(dup(fileno(STDIN)), "r");
      my $output_stream = IO::Handle::->new_from_fd(dup(fileno(STDOUT)), "w");

      my $devnull = File::Spec->devnull();
      open(STDIN, "$devnull");
      open(STDOUT, ">$devnull");
      open(STDERR, ">$devnull");
      while (sysread($input_stream, $buffer, 1024 * 32)) {
        last if $buffer =~ /kill/;
        my $l = "child [$$] read: $buffer";
        syswrite($output_stream,$l,length($l));
      }
    },
    StdoutEvent => 'output'
  );
  ok($self->{subprocess}, "we have a subprocess");
  $heap->{counter} = 3;
  $kernel->delay_set('next', 1);
}

sub output {
  my ($self, $output) = @_[OBJECT, ARG0];
  chomp $output;
  diag "received data from subprocess: [$output]\n";
}

sub reaper {
  my ($self, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];
  ok(!$heap->{counter}, "child has exited when the counter ran out");
  $self->{subprocess} = undef;
  $kernel->sig_handled;
}

sub next {
  my ($self, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];
  diag "next [$heap->{counter}]\n";
  if ($self->{subprocess}) {
    $self->{subprocess}->put("Can you hear me $heap->{counter}");
  }
  if (--$heap->{counter}) {
    $kernel->delay_set('next', 1)
  }
  elsif ($self->{subprocess}) {
    diag "Trying to kill [" . $self->{subprocess}->PID . "]\n";
    $self->{subprocess}->put("kill");
  }
}

