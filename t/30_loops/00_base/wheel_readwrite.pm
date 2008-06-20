#!/usr/bin/perl -w

use strict;
use warnings;
use IO::File;

use Test::More tests => 28;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw(Filter::Map Driver::SysRW Pipe::TwoWay);

sub DEBUG () { 0 }

use_ok('POE::Wheel::ReadWrite');
can_ok('POE::Wheel::ReadWrite',
  qw( new put event set_filter set_input_filter set_output_filter
      set_high_mark set_low_mark get_driver_out_octets get_driver_out_messages
      ID pause_input resume_input shutdown_input shutdown_output ));

# checks new() fails appropriately
sub test_new {
  my ($name, @args) = @_;
  eval { POE::Wheel::ReadWrite->new(@args) };
  ok($@ ne '', $name);
}

# Part 0 - Dispatch tests {{{
sub test_dispatcher {
  my @tests = ( \&part1, \&part2, \&part3 );
  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[KERNEL]->yield('run_next');
        $_[KERNEL]->alias_set('test_dispatcher');
      },
      run_next => sub {
        if (@tests) {
          warn "dispatching $tests[0]" if DEBUG;
          eval { (shift @tests)->() };
          if ($@) { warn $@; exit 1; }
          # POE isn't very good at dieing hard
        } else {
          $_[KERNEL]->alias_remove('test_dispatcher');
        }
      },
      _child => sub {
        if ($_[ARG0] eq 'lose') {
          delete $_[HEAP]->{$_[ARG1]->ID};
          $_[KERNEL]->yield('run_next') unless keys %{$_[HEAP]};
        } else {
          $_[HEAP]->{$_[ARG1]->ID}++;
        }
      },
      _stop => sub { },
    },
  );
}
# }}}

# Appendix 1 - Mock/Proxy Driver {{{
{
  package MockDriver;
  # Those readers interested in good practice should see Test::MockObject
  use vars qw($AUTOLOAD);
  sub SELF_DRIVER () { 0 }
  sub SELF_CALLED () { 1 }
  sub new {
    my ($class, $driver) = @_;
    return bless [$driver, {}], $class;
  }
  sub mock_called {
    my ($self, $meth) = @_;
    return $self->[SELF_CALLED]->{$meth};
  }
  sub DESTROY { }
  sub AUTOLOAD {
    my $self = shift;
    $AUTOLOAD =~ s/^MockDriver:://;
    my $meth = $self->[SELF_DRIVER]->can($AUTOLOAD);
    $self->[SELF_CALLED]->{$AUTOLOAD}++;
    unshift @_, $self->[SELF_DRIVER];
    goto &$meth;
  }
}
# }}}

# Part 1 - Check new() {{{
sub part1 {
  POE::Session->create(
    inline_states => {
      _start => sub {
        test_new("new(): no args");
        test_new("new(): passing kernel deprecated", $poe_kernel);
        test_new("new(): handles for both directions", InputHandle => \*STDIN);
        local $SIG{__WARN__} = sub {};
        test_new("new(): both marks must be given",
          Handle => \*DATA, HighMark => 5,
          HighEvent => 'high', LowEvent => 'low');
        test_new("new(): both marks must be given",
          Handle => \*DATA, LowMark => 5,
          HighEvent => 'high', LowEvent => 'low');
        test_new("new(): both marks must be valid",
          Handle => \*DATA, LowMark => 5, HighMark => -1,
          HighEvent => 'high', LowEvent => 'low');
        test_new("new(): both marks must be valid",
          Handle => \*DATA, LowMark => -1, HighMark => 5,
          HighEvent => 'high', LowEvent => 'low');
        test_new("new(): both marks must be valid",
          Handle => \*DATA, LowMark => -1, HighMark => -1,
          HighEvent => 'high', LowEvent => 'low');
        test_new("new(): both mark events needed",
          Handle => \*DATA, LowMark => 3, HighMark => 8,
          HighEvent => 'high');
        test_new("new(): both mark events needed",
          Handle => \*DATA, LowMark => 3, HighMark => 8,
          LowEvent => 'low');
        test_new("new(): mark events need levels",
          Handle => \*DATA, HighEvent => 'high');
        test_new("new(): mark events need levels",
          Handle => \*DATA, LowEvent => 'low');
        test_new("new(): mark events need levels",
          Handle => \*DATA, LowEvent => 'low', HighEvent => 'high');
      },
      _stop => sub { },
    },
  );
}
# }}}

# Part 2 - Check filter handling {{{
my $TMPDATA = <<"END";
TMPDATA 12345
TMPDATA ABCDE
$$ $< $> $]
END
my $TMPDATA_LINES = () = $TMPDATA =~ m/\n/g;

sub part2 {
  my $tmpfile = IO::File->new_tmpfile();
  die "Couldn't create temporary file" unless defined $tmpfile;
  print $tmpfile $TMPDATA;
  seek $tmpfile, 0, 0 or
    do { print STDERR "seek failed: $!"; exit 1 };

  if (exists $INC{'Tk.pm'}) {
    SKIP: {
      skip( "part2 doesn't work with Tk", 13 );
    }
    $poe_kernel->post("test_dispatcher" => "run_next");
    return;
  }
  elsif ($^O eq "MSWin32") {
    SKIP: {
      skip( "part2 doesn't work on windows", 13 );
    }
    $poe_kernel->post("test_dispatcher" => "run_next");
    return;
  }

  POE::Session->create(
    inline_states => {
      _start => sub {
        $_[HEAP]->{fh} = $tmpfile;
        $_[HEAP]->{driver} = MockDriver->new(POE::Driver::SysRW->new);
        $_[HEAP]->{wheel} = POE::Wheel::ReadWrite->new(
          Handle => $tmpfile,
          Driver => $_[HEAP]->{driver},
          LowMark => 1, HighMark => 12,
          InputEvent => 'wrong_input',
          FlushedEvent => 'wrong_flushed',
          ErrorEvent => 'wrong_error',
          HighEvent => 'wrong_high',
          LowEvent => 'wrong_low',
        );
        $_[HEAP]->{wheel_id} = $_[HEAP]->{wheel}->ID;

        # start state machines
        $_[HEAP]->{read_machine} = "start";
        $_[HEAP]->{write_machine} = "start";

        # try changing all the events
        $_[HEAP]->{wheel}->event(
          InputEvent => 'input',
          FlushedEvent => 'flushed',
          ErrorEvent => 'error',
          HighEvent => 'high',
          LowEvent => 'low',
        );
      },
      resume_input => sub { $_[HEAP]->{wheel}->resume_input },
      input => \&part2_input,
      flushed => \&part2_flushed,
      error => \&part2_handle,
      high => \&part2_high,
      low => \&part2_low,
      wrong_input => \&part2_wrong,
      wrong_flushed => \&part2_wrong,
      wrong_error => \&part2_wrong,
      wrong_high => \&part2_wrong,
      wrong_low => \&part2_wrong,
      _stop => \&part2_stop,
    },
  );
}

sub part2_wrong {
  print STDERR "$_[STATE] called unexpectedly";
  exit 1;
}

# two phases, first we do reads w/ pauses,  then we do writes w/ pauses.

sub part2_input {
  my ($heap, $input, $id) = @_[HEAP, ARG0, ARG1];

  $heap->{read_lines}++;
  $heap->{"called_input"}++;
  $heap->{"wrong_id"}++ if $id != $heap->{wheel_id};
  unless ($heap->{check_filters}++) {
    &part2_check_filters;
  }

  if ($heap->{read_machine} eq "start") {
    $heap->{wheel}->pause_input;
    $heap->{read_machine} = "paused";
  } elsif ($heap->{read_machine} eq 'paused') {
    if ($heap->{read_lines} == $TMPDATA_LINES) {
      # we've reached EOF while paused
      seek $heap->{fh}, 0, 0 or
        do { print STDERR "seek failed: $!"; exit 1 };
      $heap->{read_machine} = "paused+reset";
      $_[KERNEL]->delay('resume_input', 0.5);
    }
  } elsif ($heap->{read_machine} eq 'paused+reset') {
    # reading started again!
    if ($heap->{read_lines} >= 2*$TMPDATA_LINES) {
      $heap->{read_machine} = "stop";
      if ($heap->{write_machine} eq "start") {
        $heap->{wheel}->put("LINE 1");
        $heap->{write_machine} = "line2";
      }
    }
  } else {
    warn "read machine state == $heap->{read_machine}";
    delete $heap->{wheel};
  }
}

sub part2_flushed {
  my ($heap, $id) = @_[HEAP, ARG0];
  $heap->{called_flushed}++;
  $heap->{wrong_id}++ if $id != $heap->{wheel_id};

  if ($heap->{write_machine} eq "line2") {
    $heap->{wheel}->put("LINE 2");
    $heap->{wheel}->put("LINE 3");
    $heap->{wheel}->put("LINE 4");
    $heap->{write_machine} = "line5";
  } elsif ($heap->{write_machine} eq "line5") {
#    $heap->{wheel}->set_high_mark(550);
#    $heap->{wheel}->set_low_mark(500);

    $heap->{wheel}->put("LINE 5");
    $heap->{wheel}->put("LINE 6");
    $heap->{wheel}->put("LINE 7");
    $heap->{write_machine} = "delete";
  } elsif ($heap->{write_machine} eq "delete") {
    $heap->{write_machine} = "stop";
    $heap->{wheel}->shutdown_input;
    $heap->{wheel}->shutdown_output;
    delete $heap->{wheel};
  } else {
    warn "write machine state == $heap->{write_machine}";
    delete $heap->{wheel};
  }
}

sub part2_high {
  my $heap = $_[HEAP];
  $heap->{called_high}++;
}

sub part2_low {
  my $heap = $_[HEAP];
  if ($heap->{write_machine} eq 'delete') {
    $heap->{low_not_set}++;
  }
  $heap->{called_low}++;
}

sub part2_check_filters {
  isa_ok($_[HEAP]->{wheel}->get_input_filter, 'POE::Filter',
    "input filter isa POE::Filter");
  isa_ok($_[HEAP]->{wheel}->get_output_filter, 'POE::Filter',
    "output filter isa POE::Filter");
}

sub part2_handle {
  $_[HEAP]->{"called_$_[STATE]"}++;
}

sub part2_stop {
  my $heap = $_[HEAP];
  # the post-mortem - check that things we expected to happen, happened
  ok($heap->{called_input}, "input event happened");
  ok($heap->{called_flushed}, "flushed event happened");
  ok($heap->{called_error}, "error event happened");
#  ok($heap->{called_high}, "high event happened");
  ok($heap->{called_low}, "low event happened");
#  ok(!$heap->{low_not_set}, "low mark successfully changed");
  ok($heap->{driver}->mock_called('get'), "driver's get called");
  ok($heap->{driver}->mock_called('put'), "driver's put called");
  ok($heap->{driver}->mock_called('flush'), "driver's flush called");
  ok(!$heap->{wrong_id}, "correct wheel id consistently used");
  is($heap->{read_lines}, 2*$TMPDATA_LINES, "correct number of lines read");
  is($heap->{read_machine}, "stop", "read state machine finished");
  is($heap->{write_machine}, "stop", "write state machine finished");
}
# }}}

# Part 3 - Changing watermarks (testing with a pipe) {{{
sub part3 {
  POE::Session->create(
    inline_states => { _start => sub { }, _stop => sub { } },
  );
  return; # skip

  # create the pipe
  my ($a_read, $a_write, $b_read, $b_write) = POE::Pipe::TwoWay->new("inet");
  # flow is $b_write --> $a_read

  # the two session IDs
  my ($sender, $receiver);

  # sender
  POE::Session->create(
    inline_states => {
      problem => sub {
        diag("problem in part3 sender!");
        $_[HEAP]->{wheel} = $_[HEAP]->{fh} = undef;
      },
      _start => sub {
        $sender = $_[SESSION]->ID;

        $_[HEAP]->{wheel} = POE::Wheel::ReadWrite->new(
          Handle => $b_write,
          HighMark => 1,
          LowMark => 1,
          FlushedEvent => 'flushed',
          HighEvent => 'high',
          LowEvent => 'low',
          ErrorEvent => 'problem',
        );

        # now boost the watermarks much higher
        $_[HEAP]->{wheel}->set_high_mark(512);
        $_[HEAP]->{wheel}->set_low_mark(32);

        $_[HEAP]->{state} = "start";
        $_[HEAP]->{wheel}->put("start");
      },
      second => sub {
        is($_[HEAP]->{state}, "start", "sender: start --> second");
        $_[HEAP]->{state} = "second";
        $_[KERNEL]->yield("second_send");
      },
      second_send => sub {
        if ($_[HEAP]->{state} eq "second") {
          $_[HEAP]->{wheel}->put("\0" x (1024*1024));
          $_[KERNEL]->yield("second_send");
        }
      },
      flushed => sub { }, #print "flushed\n" },
      high => sub { print "high\n"; $_[HEAP]->{state} = "high"; },
      low => sub { print "low\n" },
      _stop => sub { },
    },
  );

  # receiver
  POE::Session->create(
    inline_states => {
      problem => sub {
        diag("problem in part3 receiver!");
        $_[HEAP]->{wheel} = $_[HEAP]->{fh} = undef;
      },
      _start => sub {
        $receiver = $_[SESSION]->ID;

        $_[HEAP]->{wheel} = POE::Wheel::ReadWrite->new(
          Handle => $a_read,
          InputEvent => 'input',
          ErrorEvent => 'problem',
        );

        $_[HEAP]->{state} = "start";
      },
      input => sub {
        my ($heap, $line) = @_[HEAP, ARG0];
        my $state = $heap->{state};
        if ($state eq "start") {
          is($line, "start", "first line ok");
          $heap->{state} = "second";
          $heap->{wheel}->pause_input();
          $_[KERNEL]->post($sender, "second");
        } elsif ($state eq "second") {
          is($line, "second", "second line ok");
        } else {
          warn "weird receive state $_[HEAP]->{state}";
          delete $heap->{wheel};
        }
      },
      _stop => sub { },
    },
  );
}
# }}}

# Start it all off
test_dispatcher();
$poe_kernel->run();

1;
