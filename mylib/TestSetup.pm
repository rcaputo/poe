# Standard test setup things.
# $Id$

package TestSetup;

use strict;

use Exporter;
@TestSetup::ISA = qw(Exporter);
@TestSetup::EXPORT = qw( &test_setup
                         &stderr_pause &stderr_resume
                         &ok &not_ok &ok_if &ok_unless &results
                         &many_not_ok &many_ok
                       );

my $test_count;
my @test_results;

sub TRACE_RESULTS () { 0 }

sub test_setup {
  $test_count = shift;

  $ENV{PERL_DL_NONLAZY} = 0 if ($^O eq 'freebsd');
  select(STDOUT); $|=1;

  if ($test_count) {
    print "1..$test_count\n";
  }
  else {
    my $reason = join(' ', @_);
    $reason = 'no reason' unless defined $reason and length $reason;
    print "1..0 # skipped: $reason\n";
    exit 0;
  }

  for (my $test = 1; $test <= $test_count; $test++) {
    $test_results[$test] = undef;
  }
}

# Opened twice to avoid a warning.
open STDERR_HOLD, '>&STDERR' or die "cannot save STDERR: $!";
open STDERR_HOLD, '>&STDERR' or die "cannot save STDERR: $!";

sub stderr_pause {
  close STDERR;
}

sub stderr_resume {
  open STDERR, '>&STDERR_HOLD' or print "cannot restore STDERR: $!";
}

sub results {
  for (my $test = 1; $test < @test_results; $test++) {
    if (defined $test_results[$test]) {
      print $test_results[$test], "\n";
    }
    else {
      print "not ok $test # no test result\n";
    }
  }
}

sub ok {
  my ($test_number, $reason) = @_;

  if (defined $test_results[$test_number]) {
    $test_results[$test_number] = "not ok $test_number # duplicate outcome";
  }
  elsif ($test_number > $test_count) {
    $test_results[$test_number] = "not ok $test_number # above $test_count";
  }
  else {
    $test_results[$test_number] = "ok $test_number" .
      ( (defined $reason and length $reason)
        ? " # $reason"
        : ''
      );
  }

  TRACE_RESULTS and warn "<<< $test_results[$test_number] >>>\n";
}

sub not_ok {
  my ($test_number, $reason) = @_;

  if (defined $test_results[$test_number]) {
    $test_results[$test_number] = "not ok $test_number # duplicate outcome";
  }
  elsif ($test_number > $test_count) {
    $test_results[$test_number] = "not ok $test_number # above $test_count";
  }
  else {
    $test_results[$test_number] = "not ok $test_number" .
      ( (defined $reason and length $reason)
        ? " # $reason"
        : ''
      );
  }

  TRACE_RESULTS and warn "<<< $test_results[$test_number] >>>\n";
}

sub many_not_ok {
  my ($start_number, $end_number, $reason) = @_;

  for (my $test = $start_number; $test <= $end_number; $test++) {
    &not_ok($test, $reason);
  }
}

sub many_ok {
  my ($start_number, $end_number, $reason) = @_;

  for (my $test = $start_number; $test <= $end_number; $test++) {
    &ok($test, $reason);
  }
}

sub ok_if {
  my ($test_number, $value, $reason) = @_;

  if ($value) {
    &ok($test_number);
  }
  else {
    &not_ok($test_number, $reason);
  }
}

sub ok_unless {
  my ($test_number, $value, $reason) = @_;

  unless ($value) {
    &ok($test_number);
  }
  else {
    &not_ok($test_number, $reason);
  }
}

1;
