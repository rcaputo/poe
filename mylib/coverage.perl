#!/usr/bin/perl -w
# $Id$

# Runs t/*.t with the custom Devel::Trace to check for source
# coverage.

use strict;
use lib qw( . .. ../lib );

my %statistics;
sub CALL_COUNT  () { 0 }
sub SUB_NAME    () { 1 }
sub SOURCE_CODE () { 2 }

# Ignore most signals.

foreach (keys %SIG) {
  next if /^(__.*__|CH?LD|INT)$/;
  next unless defined $SIG{$_};
  $SIG{$_} = 'IGNORE';
}

# Find the tests.

my $test_directory =
  ( (-d './t')
    ? './t'
    : ( (-d '../t')
        ? '../t'
        : die "can't find the test directory at ./t or ../t"
      )
  );

opendir T, $test_directory or die "can't open directory $test_directory: $!";
my @test_files = map { $test_directory . '/' . $_ } grep /\.t$/, readdir T;
closedir T;

# Run each test with coverage statistics.

# Skip actual runs for testing.
# goto SPANG;

foreach my $test_file (@test_files) {

  unlink "$test_file.coverage";

  $test_file =~ /\/(\d+)_/;
  my $test_number = $1 + 0;
  if (@ARGV) {
    next unless grep /^0*$test_number$/, @ARGV;
  }

  print "*** Testing $test_file ...\n";

  # System returns 0 on success.
  my $result =
    system( '/usr/bin/perl',
            '-Ilib', '-I../lib', '-I.', '-I..', '-d:Trace', $test_file
          );
  warn "error running $test_file: ($result) $!" if $result;
}

SPANG:

# Combine coverage statistics across all files.

foreach my $test_file (@test_files) {
  my $results_file = $test_file . '.coverage';

  unless (-f $results_file) {
    warn "can't find expected file: $results_file";
    next;
  }

  unless (open R, "<$results_file") {
    warn "couldn't open $results_file for reading: $!";
    next;
  }

  while (<R>) {
    chomp;
    my ($file, $line, $count, $sub, $source) = split /\t/;

    if (exists $statistics{$file}->{$line}) {
      $statistics{$file}->{$line}->[CALL_COUNT] += $count;
      if ($statistics{$file}->{$line}->[SOURCE_CODE] ne $source) {
        $statistics{$file}->{$line}->[SOURCE_CODE] = '(varies)';
      }
    }
    else {
      $statistics{$file}->{$line} = [ $count, $sub, $source ];
    }
  }

  close R;

  # unlink $results_file;
}

# Summary first.

open REPORT, '>coverage.report' or die "can't open coverage.report: $!";

print REPORT "***\n*** Coverage Summary\n***\n\n";

printf( REPORT
        "%-35.35s = %5s / %5s = %7s\n",
        'Source File', 'Ran', 'Total', 'Covered'
      );

my $ueber_total = 0;
my $ueber_called = 0;
foreach my $file (sort keys %statistics) {
  next unless $file =~ /^POE.*\.pm$/;

  my $file_total = 0;
  my $file_called = 0;
  my $lines = $statistics{$file};
  my @uncalled;

  foreach my $line (sort { $a <=> $b } keys %$lines) {
    $file_total++;
    if ($lines->{$line}->[CALL_COUNT]) {
      $file_called++;
    }
    else {
      push @uncalled, $line;
    }
  }

  $ueber_total  += $file_total;
  $ueber_called += $file_called;

  # Division by 0 is generally frowned upon.
  $file_total = 1 unless $file_total;

  printf( REPORT
          "%-35.35s = %5d / %5d = %6.2f%%\n",
          $file, $file_called, $file_total, ($file_called / $file_total) * 100
        );
}

# Division by 0 is generally frowned upon.
$ueber_total = 1 unless $ueber_total;

printf( REPORT
        "%-35.35s = %5d / %5d = %6.2f%%\n", 'All Told',
        $ueber_called, $ueber_total, ($ueber_called / $ueber_total) * 100
      );

# Now detail.

foreach my $file (sort keys %statistics) {
  my $lines = $statistics{$file};
  my $this_sub = '';
  foreach my $line (sort { $a <=> $b } keys %$lines) {
    unless ($lines->{$line}->[CALL_COUNT]) {
      if ($this_sub ne $lines->{$line}->[SUB_NAME]) {
        $this_sub = $lines->{$line}->[SUB_NAME];
        print REPORT "\n*** Uninstrumented lines in $file sub $this_sub:\n\n";
      }
      printf REPORT "%5d : %-70.70s\n", $line, $lines->{$line}->[SOURCE_CODE];
    }
  }
}

close REPORT;

print "\nA coverage report has been written to coverage.report.\n";

exit;
