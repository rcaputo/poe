#!/usr/bin/perl -w
# $Id$

use strict;
use lib qw(./mylib ../mylib);
use Socket;

use Test::More;

# Skip these tests if fork() is unavailable.
# We can't test_setup(0, "reason") because that calls exit().  And Tk
# will croak if you call BEGIN { exit() }.  And that croak will cause
# this test to FAIL instead of skip.
our $RUNNING_WIN32;
BEGIN {
  my $error;
  if ($^O eq "MacOS") {
    $error = "$^O does not support fork";
  }

  if ($^O eq "MSWin32") {
    eval 'use Win32::Console';
    if ($@) {
      $error = "$^O needs Win32::Console for this test";
    }
    elsif (exists $INC{"Event.pm"}) {
      $error = "$^O\'s fork() emulation breaks Event";
    }

    $RUNNING_WIN32 = 1;
  }

  if ($error) {
    plan skip_all => $error;
    CORE::exit();
  }

  sub STD_TEST_COUNT () { 8 }

  plan tests => 4 + 15 + 8 + 8 + 8*STD_TEST_COUNT;
}

# Turn on extra debugging output within this test program.
sub DEBUG () { 0 }

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw(Wheel::Run Filter::Line);

# the child program comes in two varieties: {{{
# - a string suitable for running with system()
# - a coderef

my ($chld_program_string, $chld_program_coderef);
{
  my $text = <<'END';
my $out = shift;
my $err = shift;
local $/ = q(!);
local $\ = q(!);
my $notify_eof_flag = 0;
select STDERR; $| = 1; select STDOUT; $| = 1;
my $eof_counter = 0;
OUTER: while (1) {
  $eof_counter++;
  CORE::exit if $eof_counter > 10;
  while (<STDIN>) {
    chomp;
    $eof_counter = 0;
    last OUTER if /^bye/;
    $notify_eof_flag = 1 if s/^notify eof/out/;
    print(STDOUT qq($out: $$)) if /^pid/;
    print(STDOUT qq($out: $_)) if s/^out //;
    print(STDERR qq($err: $_)) if s/^err //;
  }
}
if ($notify_eof_flag) {
  print(STDOUT qq($out: got eof));
  sleep 10;
}
END
  $text =~ s/\n/ /g;

  my $os_quote = ($^O eq 'MSWin32') ? q(") : q(');
  $chld_program_string = [ $^X, "-we", "$text CORE::exit 0" ];

  $chld_program_coderef = eval
    "sub { \$! = 1; " . $text . " }";
  die $@ if $@;
}

my $shutdown_program = sub {
  my $out = shift;
  my $err = shift;
  select STDERR; $| = 1; select STDOUT; $| = 1;
  local $/ = q(!);
  local $\ = q(!);
  my $flag = 0;
  $SIG{ALRM} = sub { die "alarm\n" };
  eval {
    alarm(10);
    while (<STDIN>) {
      chomp;
      if (/flag (\d+)/) { $flag = $1 }
      elsif (/out (\S+)/) { print STDOUT "$out: $1" }
    }
  };
  alarm(0);
  if ($@ eq "alarm\n") {
    print STDOUT "$out: got alarm";
  }
  else {
    print STDOUT "$out: got eof $flag";
  }
};
# }}}

{ # manage a global timeout {{{
  sub TIMEOUT_HALFTIME () { 10 }
  my $timeout_initialized = 0;
  my $timeout_poked = 0;
  my $timeout_refs = 0;

  create_timeout_session();

  sub create_timeout_session {
    my $sess = POE::Session->create(
      inline_states => {
        _start => sub {
          $_[KERNEL]->alias_set("timeout") and return;
          $_[KERNEL]->delay(check_timeout => TIMEOUT_HALFTIME);
        },
        check_timeout => sub {
          unless ($timeout_poked) {
            warn "inactivity timeout reached!";
            CORE::exit 1;
          } else {
            $timeout_poked = 0;
            $_[KERNEL]->delay(check_timeout => TIMEOUT_HALFTIME);
          }
        },
        try_shutdown => sub {
          return unless $timeout_refs == 0;
          $_[KERNEL]->delay(check_timeout => undef);
          $_[KERNEL]->alias_remove("timeout");
        },
      },
    );
    return $sess->ID;
  }

  sub timeout_poke {
    $timeout_poked++;
  }

  sub timeout_incref {
    timeout_poke();
    $timeout_refs++;
  }

  sub timeout_decref {
    timeout_poke();
    $timeout_refs--;
    if ($timeout_refs == 0) {
      $poe_kernel->post("timeout", "try_shutdown");
    }
  }
} # }}}

{ # {{{ a proxy around POE::Filter::Line that doesn't support get_one
  package My::LineFilter;
  sub new {
    my $class = shift;
    return bless [ POE::Filter::Line->new(@_) ], $class;
  }
  sub get { my $s = shift; return $s->[0]->get(@_) }
  sub put { my $s = shift; return $s->[0]->put(@_) }
} # }}}

# next follow some event handles that are used in constructing
# each session in &create_test_session
sub do_nonexistent {
  warn "$_[STATE] called on session ".$_[SESSION]->ID." ($_[HEAP]->{label})";
  CORE::exit 1;
}

sub do_error {
  DEBUG and warn "$_[HEAP]->{label}: $_[ARG0] error $_[ARG1]: $_[ARG2]";
}

# {{{ definition of the main test session
sub main_perform_state {
  my $heap = $_[HEAP];

  return unless @{$heap->{expected}};
  return unless defined $heap->{expected}->[0][0];

  my $action = $heap->{expected}->[0][0];

  unless (ref $action) {
    DEBUG and warn "$heap->{label}: performing put state: $action";
    eval { $heap->{wheel}->put( $action ) };
  } elsif ($action->[0] =~ m/^(?:pause|resume)_std(?:out|err)$/) {
    my $method = $action->[0];
    DEBUG and warn "$heap->{label}: performing method state: $method";
    $heap->{wheel}->$method();
  } elsif ($action->[0] eq "kill") {
    DEBUG and warn "$heap->{label}: performing kill";
    $heap->{wheel}->kill();
  } elsif ($action->[0] eq "shutdown_stdin") {
    DEBUG and warn "$heap->{label}: shutdown_stdin";
    $heap->{wheel}->shutdown_stdin();
  } else {
    warn "weird action @$action, this is a bug in the test script";
    CORE::exit 1;
  }

  # sometimes we don't have anything to wait for, so
  # just perform the next action
  if (not defined $heap->{expected}->[0][1]) {
    shift @{$heap->{expected}};
    goto &main_perform_state;
  }
}

my $main_counter = 0;
sub main_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  my ($label, $program, $conduit, $expected) = @_[ARG0..$#_];

  $heap->{label} = $label;

  # Handle SIGCHLD
  $kernel->sig(CHLD => "sigchld");

  # Sometimes use a filter without get_one support
  my $filter_class = "POE::Filter::Line";
  if ($main_counter++ % 2) {
    $filter_class = "My::LineFilter";
  }

  # Run the child process
  my $no_stderr = (defined $conduit and $conduit eq "pty");
  $heap->{wheel} = POE::Wheel::Run->new(
    Program => $program,
    ProgramArgs => [ "out$$", "err$$" ], # we assume $program expects this
    (defined $conduit ? (Conduit => $conduit) : ()),
    StdioFilter => $filter_class->new( Literal => "!" ),
    (!$no_stderr ? (StderrFilter => $filter_class->new( Literal => "!" ))
      : ()),
    StdoutEvent  => 'stdout_nonexistent',
    (!$no_stderr ? (StderrEvent  => 'stderr_nonexistent') : ()),
    StdinEvent   => 'stdin_nonexistent',
    ErrorEvent   => 'error_nonexistent',
    CloseEvent   => 'close_nonexistent',
  );

  # Test event changing.
  $heap->{wheel}->event(
    StdoutEvent => 'stdout',
    (!$no_stderr ? (StderrEvent => 'stderr') : ()),
    StdinEvent  => 'stdin',
  );
  $heap->{wheel}->event(
    ErrorEvent  => 'error',
    CloseEvent  => 'close',
  );

  # start the test statemachine
  $heap->{expected} = [@$expected];
  &main_perform_state;

  $heap->{flushes_expected} = scalar
    grep { (!ref $_->[0]) and defined($_->[1]) } @$expected;
  $heap->{flushes} = 0;

  # timeout delay
  timeout_incref();

  DEBUG and warn "$heap->{label}: _start";
}

my $x__ = 0;
sub main_stop {
  my $heap = $_[HEAP];
  is( $heap->{flushes}, $heap->{flushes_expected},
    "$heap->{label} flush count ($$)" )
    unless $heap->{ignore_flushes};
  DEBUG and warn "$heap->{label}: _stop ($$)";
}

sub main_stdin {
  my $heap = $_[HEAP];
  $heap->{flushes}++;
  timeout_poke();
  DEBUG and warn "$heap->{label}: stdin flush";
}

sub main_output {
  my ($heap, $state) = @_[HEAP, STATE];
  my $input = $_[ARG0];

  my $prefix = $heap->{expected}->[0][1][2] . $$;

  $heap->{expected}->[0][1][1] = $heap->{wheel}->PID
    unless defined $heap->{expected}->[0][1][1];

  is($state, $heap->{expected}->[0][1][0],
    "$heap->{label} response type");
  is($input, "$prefix: ".$heap->{expected}->[0][1][1],
    "$heap->{label} $state response");

  DEBUG and warn "$heap->{label}: $state $input";

  timeout_poke();

  shift @{$heap->{expected}};
  &main_perform_state;
}

sub main_close {
  my ($heap, $kernel) = @_[HEAP, KERNEL];
  is('close', $heap->{expected}->[0][1][0],
    "$heap->{label} close");
  is($_[HEAP]->{wheel}->get_driver_out_octets, 0,
    "$heap->{label} driver_out_octets at close")
    unless $heap->{ignore_flushes};
  is($_[HEAP]->{wheel}->get_driver_out_messages, 0,
    "$heap->{label} driver_out_messages at close")
    unless $heap->{ignore_flushes};
  delete $_[HEAP]->{wheel};
  timeout_decref();
  $kernel->sig("CHLD" => undef);
  DEBUG and warn "$heap->{label}: close";
}

sub main_sigchld {
  my $heap = $_[HEAP];
  my ($signame, $child_pid) = @_[ARG0, ARG1];

  my $our_child = $heap->{wheel} ? $heap->{wheel}->PID : -1;
  DEBUG and warn "$heap->{label}: sigchld $signame for $child_pid ($our_child)";

  return unless $heap->{wheel} and $our_child == $child_pid;

  # turn it into a close
  &main_close;
}

sub create_test_session {
  my ($label, $program, $conduit, $expected, $ignore_flushes) = @_;

  my $sess = POE::Session->create(
    args => [$label, $program, $conduit, $expected],
    heap => { ignore_flushes => $ignore_flushes },
    inline_states => {
      _start => \&main_start,
      _stop => \&main_stop,
      error => \&do_error,
      close => \&main_close,
      stdin => \&main_stdin,
      stdout => \&main_output,
      stderr => \&main_output,
      sigchld => \&main_sigchld,
      stdout_nonexistent => \&do_nonexistent,
      stderr_nonexistent => \&do_nonexistent,
      stdin_nonexistent => \&do_nonexistent,
      error_nonexistent => \&do_nonexistent,
      close_nonexistent => \&do_nonexistent,
    },
  );

  return $sess->ID;
}
# }}}

# {{{ Constructor tests
sub create_constructor_session {
  my $sess = POE::Session->create(
    inline_states => {
      _start => sub {
        eval {
          POE::Wheel::Run->new(
            Program => sub { 1; },
            ErrorEvent => 'error_event',
          );
        };
        ok(!(!$@), "new: at least one io event");

        eval {
          POE::Wheel::Run->new(
            Program => sub { 1; },
            Conduit => 'wibble-magic-pipe',
            StdoutEvent => 'stdout_event',
            ErrorEvent => 'error_event',
          );
        };
        ok(!(!$@), "new: only valid conduits");

        eval {
          POE::Wheel::Run->new(
            Program => sub { 1; },
            Filter => POE::Filter::Line->new( Literal => "!" ),
            StdioFilter => POE::Filter::Line->new( Literal => "!" ),
            StdoutEvent => 'stdout_event',
            ErrorEvent => 'error_event',
          );
        };
        ok(!(!$@), "new: cannot mix deprecated Filter with StdioFilter");

        eval {
          POE::Wheel::Run->new(
            ProgramArgs => [ "out$$", "err$$" ],
            Conduit => "pty",
            StdioFilter => POE::Filter::Line->new( Literal => "!" ),
            StderrFilter => POE::Filter::Line->new( Literal => "!" ),
            StdoutEvent  => 'stdout_nonexistent',
            StderrEvent  => 'stderr_nonexistent',
            StdinEvent   => 'stdin_nonexistent',
            ErrorEvent   => 'error_nonexistent',
            CloseEvent   => 'close_nonexistent',
          );
        };
        ok(!(!$@), "new: Program is needed");

        timeout_poke();
      },
    },
  );

  return $sess->ID;
}
# }}}

# Main program: Create test sessions {{{
my @one_stream_expected = (
  [ "out test-out", ["stdout", "test-out", "out"] ],
  [ "err test-err", ["stdout", "test-err", "err"] ], # std*out* not stderr
  [ "bye", ["close"] ],
);
my @two_stream_expected = (
  [ "out test-out", ["stdout", "test-out", "out"] ],
  [ "err test-err", ["stderr", "test-err", "err"] ],
  [ "bye", ["close"] ],
);
my @pause_resume_expected = (
  [ "out init", ["stdout", "init", "out"] ],
  [ ["pause_stdout"], undef ],
  [ "out delayed1", undef ],
  [ "err immediate1", ["stderr", "immediate1", "err"] ],
  [ ["pause_stderr"], undef ],
  [ "err delayed2", undef ],
  [ ["resume_stdout"], ["stdout", "delayed1", "out"] ],
  [ "out immediate2", ["stdout", "immediate2", "out"] ],
  [ ["resume_stderr"], ["stderr", "delayed2", "err"] ],
  [ "out immediate3", ["stdout", "immediate3", "out"] ],
  [ "err immediate4", ["stderr", "immediate4", "err"] ],
  [ "bye", ["close"] ],
);
my @killing_expected = (
  [ "out init", ["stdout", "init", "out"] ],
  [ "pid", ["stdout", undef, "out"] ],
  [ ["kill"], ["close"] ],
);
my @shutdown_expected = (
  [ "flag 1", undef],
  [ "out init", ["stdout", "init", "out"] ],
  [ ["shutdown_stdin"], undef],
  [ "flag 2", ["stdout", "got eof 1", "out"] ],
  [ ["kill"], ["close"] ],
);

my @chld_programs = (
  ["string", $chld_program_string],
  ["coderef", $chld_program_coderef],
);

# create constructor test session
create_constructor_session();

# test pausing/resuming for both stdout and stderr
create_test_session(
  "string/pause_resume",
  $chld_program_string,
  undef,
  \@pause_resume_expected,
);
SKIP: {
  skip "PIDs and shutdown don't work on windows", 13
    if $RUNNING_WIN32;
  # testing killing, and PID
  create_test_session(
    "string/killing",
    $chld_program_string,
    undef,
    \@killing_expected,
  ); # needs to be skipped on windows
  # test shutdown_stdin
  create_test_session(
    "coderef/shutdown",
    $shutdown_program,
    "pipe",
    \@shutdown_expected,
    1, # ignore flush counts etc
  );
}

for my $chld_program (@chld_programs) {
  my ($chld_name, $chld_code) = @$chld_program;

  create_test_session(
    "$chld_name/default",
    $chld_code, # program
    undef, # conduit
    \@two_stream_expected # expected
  );

  SKIP: {
    skip "$chld_name/pipe: doesn't work on windows", STD_TEST_COUNT
      if $RUNNING_WIN32;
    create_test_session(
      "$chld_name/pipe",
      $chld_code, # program
      "pipe", # conduit
      \@two_stream_expected # expected
    );
  }

  SKIP: {
    skip "$chld_name/pty: IO::Pty is needed for this test.", 2*STD_TEST_COUNT
      unless POE::Wheel::Run::PTY_AVAILABLE;

    skip "$chld_name/pty: The underlying event loop has trouble with ptys on $^O", 2*STD_TEST_COUNT
      if $^O eq "darwin" and (
        exists $INC{"POE/Loop/IO_Poll.pm"} or
        exists $INC{"POE/Loop/Event.pm"}
      );

    create_test_session(
      "$chld_name/pty",
      $chld_code, # program
      "pty", # conduit
      \@one_stream_expected # expected
    );
    create_test_session(
      "$chld_name/pty-pipe",
      $chld_code, # program
      "pty-pipe", # conduit
      \@two_stream_expected # expected
    );
  }
}
# }}}

$poe_kernel->run;

1;
