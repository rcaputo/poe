#!/usr/bin/perl -w
# vim: ts=2 sw=2 expandtab

# POE::Kernel should be able to handle daemonization with no issues

# enable this to get debugging output
sub DEBUG () { 0 }

BEGIN {
  my $error;
  if ($^O eq "MSWin32") {
    $error = "$^O does not support fork()";
  } elsif ( ! $ENV{RELEASE_TESTING} && ! $ENV{AUTOMATED_TESTING} ) {
    $error = "enable by setting (AUTOMATED|RELEASE)_TESTING";
  }

  if ($error) {
    print "1..0 # Skip $error\n";
    exit;
  }
}

use strict;

use lib qw(./mylib ../mylib);

use POE;
use POE::Wheel::Run;
use POE::Wheel::FollowTail;
use POE::Filter::Reference;
use POE::Filter::Line;
use File::Temp qw( tempfile );

# 3 sets of daemonization methods * 2 timing of daemonization * run has_forked() or not?
use Test::More tests => 12;

my @tests;
foreach my $t ( qw( nsd dd mxd ) ) {
  # nsd = Net::Server::Daemonize ( single-fork )
  # dd = Daemon::Daemonize ( double-fork )
  # mxd = MooseX::Daemonize ( single-fork with some extra stuff )

  foreach my $timing ( qw( before after ) ) {
    foreach my $forked ( qw( has_fork no_fork ) ) {
      push( @tests, [ $t, $timing, $forked ] );
    }
  }
}
my_spawn( @{ pop @tests } );

sub my_spawn {
  POE::Session->create(
    package_states => [
      'main' => [qw(_start _stop _timeout _wheel_stdout _wheel_stderr _wheel_closed _wheel_child _daemon_input _child)],
    ],
    'args' => [ @_ ],
  );
}

POE::Kernel->run();

sub _child {
  return;
}

sub _start {
  my ($kernel,$heap,$type,$timing,$forked) = @_[KERNEL,HEAP,ARG0 .. ARG2];
  $heap->{type} = $type;
  $heap->{timing} = $timing;
  $heap->{forked} = $forked;

  # Create a tempfile to communicate with the daemon
  my ($fh,$filename) = tempfile( UNLINK => 1 );
  $heap->{follow} = POE::Wheel::FollowTail->new(
    Handle => $fh,
    InputEvent => '_daemon_input',
  );

  my $program = [ $^X, '-e', 'use lib qw(./mylib ../mylib); require "ForkingDaemon.pm";' ];

  $heap->{wheel} = POE::Wheel::Run->new(
    Program      => $program,
    StdoutEvent  => '_wheel_stdout',
    StdinFilter  => POE::Filter::Reference->new,
    StderrEvent  => '_wheel_stderr',
    StdoutFilter => POE::Filter::Line->new,
    ErrorEvent   => '_wheel_error',
    CloseEvent   => '_wheel_closed',
  );

  # tell the daemon to go do it's stuff and communicate with us via the tempfile
  $heap->{wheel}->put( {
    file => $filename,
    timing => $timing,
    type => $type,
    forked => $forked,
    debug => DEBUG(),
  } );

  $kernel->sig_child( $heap->{wheel}->PID, '_wheel_child' );
  $kernel->delay( '_timeout', 10 );
  return;
}

sub _daemon_input {
  my ($kernel,$heap,$input) = @_[KERNEL,HEAP,ARG0];

  if ( $input eq 'DONE' ) {
    # we are done testing!
    pass( "POE ($heap->{type}|$heap->{timing}|$heap->{forked}) successfully exited" );

    # cleanup
    undef $heap->{wheel};
    undef $heap->{follow};
    $kernel->delay( '_timeout' );

    # process the next test combination!
    my_spawn( @{ pop @tests } ) if @tests;
  } elsif ( $input =~ /^OLDPID\s+(.+)$/ ) {
    # got the PID before daemonization
    warn "Got OLDPID($heap->{type}|$heap->{timing}|$heap->{forked}): $1" if DEBUG;
    $heap->{daemon} = $1;
  } elsif ( $input =~ /^PID\s+(.+)$/ ) {
    # got the PID of the daemonized process
    my $pid = $1;
    warn "Got PID($heap->{type}|$heap->{timing}|$heap->{forked}): $pid" if DEBUG;
    if ( $heap->{daemon} == $pid ) {
      die "Failed to fork!";
    }
    $heap->{daemon} = $pid;
  } else {
    warn "daemon($heap->{type}|$heap->{timing}|$heap->{forked}): $input\n" if DEBUG;
  }

  return;
}

sub _wheel_stdout {
  my ($heap) = $_[HEAP];
  warn "daemon($heap->{type}|$heap->{timing}|$heap->{forked}) STDOUT: " . $_[ARG0] if DEBUG;
  return;
}

sub _wheel_stderr {
  my ($heap) = $_[HEAP];
  warn "daemon($heap->{type}|$heap->{timing}|$heap->{forked}) STDERR: " . $_[ARG0] if DEBUG;
  return;
}

sub _wheel_closed {
  undef $_[HEAP]->{wheel};
  return;
}

sub _wheel_child {
  $poe_kernel->sig_handled();
  return;
}

sub _stop {
  return;
}

sub _timeout {
  my $heap = $_[HEAP];

  # argh, we have to kill the daemonized process
  if ( exists $heap->{daemon} ) {
    CORE::kill( 9, $heap->{daemon} );
  } else {
    die "Something went seriously wrong";
  }

  fail( "POE ($heap->{type}|$heap->{timing}|$heap->{forked}) successfully exited" );

  # cleanup
  undef $heap->{wheel};
  undef $heap->{follow};

  # process the next test combination!
  my_spawn( @{ pop @tests } ) if @tests;

  return;
}
