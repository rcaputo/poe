#!/usr/bin/perl -w
# $Id$

# Runs t/*.t with the custom Devel::Trace to check for source
# coverage.

use strict;
use lib qw( . .. ../mylib );

sub DEBUG  () { 0 } # skip running tests to better debug this one
sub UNLINK () { 1 } # unlink coverage files when done (disable for testing)

sub SRC_COUNT () { 0 }
sub SRC_LINE  () { 1 }
sub SRC_SRC   () { 2 }

my (%counts, %uncalled);

# Find the tests.

use File::Find;
my @test_files;
sub wanted {
  return unless -f;
  return unless /\.t$/;
  push @test_files, $File::Find::dir . "/" . $_;
}

my $test_directory =
  ( (-d './t')
    ? './t'
    : ( (-d '../t')
        ? '../t'
        : die "can't find the test directory at ./t or ../t"
      )
  );

find(\&wanted, $test_directory);

# -><- For testing, limit the report to a single file.
#@test_files = (
#  "./t/01_sessions.t",
#  "./t/03_aliases.t",
#  "./t/04_selects.t",
#);

#@test_files = ( "./t/11_signals_poe.t", "./t/12_signals_ev.t" );
#@test_files = ( "./t/23_nfa.t" );

# Run each test with coverage statistics.

# Skip actual runs for testing.
if (DEBUG) {
  warn "not running test programs";
  goto SPANG;
}

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
            '-Imylib', '-I../mylib', '-I.', '-I..', '-d:Trace', $test_file
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

    $file =~ s/^lib\///;

    my $report_source = $source;
    $source =~ s/\s+/ /g;
    $source =~ s/^\s+//;
    $source =~ s/\s+$//;

    # Ignore preprocessor BEGIN lines.
    next if $source =~ /^BEGIN.*\#\s*include\s*$/;

    # -><- Might be proper to ignore these things when outside any
    # sub.

    # Ignore constants.
    next if $source =~ /^sub\s+\S+\s*\([^\)]*\)\s*\{.*?\};?(\s*\#.*?)?$/;

    # Ignore the 1; line at the end of a module.
    next if $source =~ /^\s*1\s*;\s*$/;

    # Ignore C<use> lines, which often falsely appear as uninstrumented.
    next if $source =~ /^use\s+/;

    # Ignore $VERSION lines.
    next if $source =~ /^\$VERSION\s*=\s*/;

    # Ignore uninitialized lines.  Sanity check them, too.
    if ($source eq '(uninitialized)') {
      die( "instrumented uninitialized line in sub $sub ",
           "in $file at line $line\n"
         )
        if $count;
      next;
    }

    # Count the initialized line.
    if (exists $counts{$file}->{$sub}->{$source}) {
      $counts{$file}->{$sub}->{$source}->[SRC_COUNT] += $count;
      $counts{$file}->{$sub}->{$source}->[SRC_LINE] = $line
        if $counts{$file}->{$sub}->{$source}->[SRC_LINE] < $line;
    }
    else {
      $counts{$file}->{$sub}->{$source} = [ $count, $line, $report_source ];
    }
  }

  close R;

  if (UNLINK) {
    unlink $results_file;
  }
}

# Summary first.

open REPORT, '>coverage.report' or die "can't open coverage.report: $!";

print REPORT "***\n*** Coverage Summary\n***\n\n";

printf( REPORT
        "%-35.35s = %5s / %5s = %7s\n",
        'Source File', 'Ran', 'Total', 'Covered'
      );

my $ueber_total  = 0;
my $ueber_called = 0;
foreach my $file (sort keys %counts) {
  next unless $file =~ /^POE.*\.pm$/;

  my $file_total  = 0;
  my $file_called = 0;
  my $subs        = $counts{$file};

  foreach my $sub (sort keys %$subs) {
    my $sub_rec = $subs->{$sub};

    foreach my $line_rec ( sort { $a->[SRC_LINE] <=> $b->[SRC_LINE] }
                           values %$sub_rec
                         ) {
      $file_total++;
      if ($line_rec->[SRC_COUNT]) {
        $file_called++;
      }
      else {
        $uncalled{$file}->{$sub} = [ ] unless exists $uncalled{$file}->{$sub};
        push @{$uncalled{$file}->{$sub}}, $line_rec;
      }
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

foreach my $file (sort keys %uncalled) {
  foreach my $sub (sort keys %{$uncalled{$file}}) {
    print REPORT "\n*** Uninstrumented lines in $file sub $sub:\n\n";

    my $sub_rec = $uncalled{$file}->{$sub};
    foreach my $line (@$sub_rec) {
      printf REPORT "%5d : %-70.70s\n", $line->[SRC_LINE], $line->[SRC_SRC];
    }
  }
}

close REPORT;

print "\nA coverage report has been written to coverage.report.\n";

exit;
