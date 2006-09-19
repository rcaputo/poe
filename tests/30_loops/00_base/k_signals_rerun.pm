# $Id$
# vim: filetype=perl

# Yuval Kogman's test case for edge issues with rethrowing unhandled
# die() exceptions and re-calling run() after it's returned due to
# such exceptions.

use warnings;
use strict;

use Test::More;

if ($^O eq "MSWin32") {
  eval 'use Win32::Console';
  if ($@) {
    plan skip_all => "Win32::Console is required on $^O - try ActivePerl";
  }
  if (exists $INC{'Tk.pm'}) {
    plan skip_all => "Perl crashes in this test with Tk on $^O";
  }
  if (exists $INC{'Event.pm'}) {
    plan skip_all => "Perl crashes in this test with Event on $^O";
  }
}

plan tests => 9;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw/Wheel::Run/;

foreach my $die_on_bad_exit ( 0, 1 ) {
  foreach my $exit ( 0, 1, 0, 0 ) {
    POE::Session->create(
      inline_states => {
        _start => sub {
          POE::Session->create(
            inline_states => {
              stdout => sub { },
              stdin => sub { },
              _start => sub {
                my ( $kernel, $session, $heap ) = @_[KERNEL, SESSION, HEAP];

                $kernel->sig( CHLD => "sigchld_handler" );

                my $wheel = POE::Wheel::Run->new(
                  Program => $heap->{program},
                  StdinEvent => "stdin",
                  StdoutEvent => "stdout",
                );

                $heap->{pid_to_wheel}->{ $wheel->PID } = $wheel;
                $heap->{id_to_wheel}->{ $wheel->ID }   = $wheel;

                $kernel->refcount_increment(
                  $session->ID, "running_processes"
                );
              },
              sigchld_handler => sub  {
                my ( $kernel, $session, $heap, $pid, $child_error ) = @_[
                  KERNEL, SESSION, HEAP, ARG1, ARG2
                ];
                return unless exists $heap->{pid_to_wheel}{$pid};

                $kernel->refcount_decrement(
                  $session->ID, "running_processes"
                );

                my $wheel = delete $heap->{pid_to_wheel}{$pid};
                delete $heap->{id_to_wheel}{ $wheel->ID };
                $kernel->sig( CHLD => undef );

                $heap->{program_exit} = $child_error;
              },
              _stop => sub {
                my ( $heap ) = $_[HEAP];

                if ( scalar keys %{ $heap->{pid_to_wheel} } ) {
                  die "AAAAAAAHHH Running process leak!";
                }

                die "bad exit\n" if $die_on_bad_exit and (
                  $heap->{program_exit} >> 8
                ) != 0;
              }
            },
            heap => { program => [ $^X, "-wle", "exit $exit" ] },
          );
        },
        _stop => sub { },
        _child => sub { },
      },
    );

    eval { POE::Kernel->run };

    if ( $die_on_bad_exit and $exit ) {
      ok( $@, "($die_on_bad_exit-$exit) died with bad exit code" );
      is( $@, "bad exit\n", "($die_on_bad_exit-$exit) error is correct" );
    }
    else {
      ok(
        !$@, "($die_on_bad_exit-$exit) no error when process exited OK"
      ) or diag($@);
    }
  }
}

1;
