# $Id$

# This is a `perl -d` debugger module that simply traces execution.
# It's optional, and it may not even work.

use strict;
package Trace; # satisfies 'use'

package DB;
use vars qw($sub);

use POSIX;

sub CALL_COUNT  () { 0 }
sub SUB_NAME    () { 1 }
sub SOURCE_CODE () { 2 }

my %statistics;
my $signal_set;

BEGIN {
  unlink "$0.coverage";
  open STATS, ">$0.coverage" or die "can't write $0.coverage: $!";
  $signal_set = POSIX::SigSet->new();
  $signal_set->fillset();
}

# &DB is called for every breakpoint that's encountered.  We use it to
# track which code is instrumented during a given program run.

sub DB {
  # Try to block signal delivery while this is recording information.
  sigprocmask( SIG_BLOCK, $signal_set );

  my ($package, $file, $line) = caller;

  # Skip lines that aren't in the POE namespace.  Skip lines ending
  # with "]", which are evals.
  return unless $package =~ /^POE/;
  return unless $file =~ /POE/ and $file !~ /\]$/;

  # Gather a statistic for this line.
  $statistics{$file}->{$line} = [ 0, '(uninitialized)', '(uninitialized)' ]
    unless exists $statistics{$file}->{$line};
  $statistics{$file}->{$line}->[CALL_COUNT]++;

  # Unblock signals now that we're done.
  sigprocmask( SIG_UNBLOCK, $signal_set );
}

# &sub is a proxy function that's used to trace function calls.  We
# don't use it for anything right now, but things seem to run better
# when it's defined.

sub sub { no strict 'refs'; &$sub; }

# After all's said and done, say what's done.

END {

  # Gather breakable lines for every file visited.  This is done at
  # the end since doing it at the beginning means some lines aren't
  # visible.

  foreach my $file (keys %statistics) {
    my $sub_name = '(unknown)';
    for (my $line=1; $line<@{$::{"_<$file"}}; $line++) {

      if ($::{"_<$file"}->[$line] =~ /^sub\s+(\S+)/) {
        $sub_name = $1;
      }

      if (exists $statistics{$file}->{$line}) {
        $statistics{$file}->{$line}->[SUB_NAME] = $sub_name;
      }
      else {
        # Here there be magic.
        local $^W = 0;
        if ($::{"_<$file"}->[$line]+0) {
          my $source = $::{"_<$file"}->[$line];
          chomp $source;
          $statistics{$file}->{$line} = [ 0, $sub_name, $source ];
        }
      }

      if ($::{"_<$file"}->[$line] =~ /^\}/) {
        $sub_name = '(unknown)';
      }
    }
  }

  foreach my $file (sort keys %statistics) {
    foreach my $line (sort keys %{$statistics{$file}}) {
      print( STATS "$file\t$line\t",
             $statistics{$file}->{$line}->[CALL_COUNT], "\t",
             $statistics{$file}->{$line}->[SUB_NAME], "\t",
             $statistics{$file}->{$line}->[SOURCE_CODE], "\n"
           );
    }
  }
  close STATS;
}

1;
__END__

END {
  my $ueber_total = 0;
  my $ueber_called = 0;

  printf( STATS "%-30.30s = %5s / %5s = %7s\n",
          'File', 'Ran', 'Total', 'Covered'
        );

  foreach my $file (sort keys %statistics) {
    my $total = 0;
    my $called = 0;
    foreach my $line (values %{$statistics{$file}}) {
      $total++;
      $called++ if $line->[CALL_COUNT];
    }
    next unless $total;
    $ueber_total += $total;
    $ueber_called += $called;
    printf( STATS "%-30.30s = %5d / %5d = %6.2f%%\n",
            $file, $called, $total, ($called / $total) * 100
          );
  }

  if ($ueber_total) {
    printf( STATS "%-30.30s = %5d / %5d = %6.2f%%\n",
            'All Told', $ueber_called, $ueber_total,
            ($ueber_called / $ueber_total) * 100
          );
  }

  foreach my $file (sort keys %statistics) {
    print STATS "\n*** Uncalled Lines tn $file\n\n";
    foreach my $line (sort { $a <=> $b } keys %{$statistics{$file}}) {
      my $call_rec = $statistics{$file}->{$line};
      next if $call_rec->[CALL_COUNT];
      my ($sub, $code) = ($call_rec->[SUB_NAME], $::{"_<$file"}->[$line]);
      $code =~ s/\n+$//;
      printf STATS "%5d: %-20.20s %-50.50s\n", $line, $sub, $code;
    }
  }

  close STATS;
}

###############################################################################
1;

__END__

-------------------------------------------------------------------------------

-------------------------------------------------------------------------------

*** Testing ./t/01_sessions.t ...
1..17
ok 1
ok 2
ok 3
ok 4

-------------------------------------------------------------------------------

*** Testing ./t/06_tk.t ...
1..8

***
*** Please note: This test will pop up a Tk window.
***
ok 1
ok 2
ok 3
ok 4
ok 5
ok 6
ok 7
ok 8

-------------------------------------------------------------------------------

*** Testing ./t/11_signals_poe.t ...
1..2

***
*** This test may run for up to two minutes.
*** This delay compensates for testing on slow machines.
***
ok 1
not ok 2 # reaped 0 out of 8
>>>>>  <<<<<
can't enqueue state(_sigchld_poll) for nonexistent session(POE::Kernel=ARRAY(0x82fcffc))
 at ./t/11_signals_poe.t line 0
error running ./t/11_signals_poe.t: (65280)  at lib/coverage.perl line 60.

-------------------------------------------------------------------------------

*** Testing ./t/12_signals_ev.t ...
1..2

***
*** This test may run for up to two minutes.
*** This delay compensates for testing on slow machines.
***
ok 1
not ok 2 # reaped 0 out of 8

-------------------------------------------------------------------------------

Use of uninitialized value in hash element at lib/coverage.perl line 91, <R> line 1174.
Use of uninitialized value in hash element at lib/coverage.perl line 91, <R> line 1174.
Use of uninitialized value in hash element at lib/coverage.perl line 91, <R> line 2002.
Use of uninitialized value in hash element at lib/coverage.perl line 91, <R> line 2002.
Use of uninitialized value in hash element at lib/coverage.perl line 91, <R> line 2350.
Use of uninitialized value in hash element at lib/coverage.perl line 91, <R> line 2350.
Use of uninitialized value in exists at lib/coverage.perl line 84, <R> line 2473.
Use of uninitialized value in hash element at lib/coverage.perl line 85, <R> line 2473.
Use of uninitialized value in addition (+) at lib/coverage.perl line 85, <R> line 2473.
Use of uninitialized value in hash element at lib/coverage.perl line 86, <R> line 2473.
Use of uninitialized value in string ne at lib/coverage.perl line 86, <R> line 2473.
Use of uninitialized value in string ne at lib/coverage.perl line 86, <R> line 2473.
Use of uninitialized value in exists at lib/coverage.perl line 84, <R> line 2596.
Use of uninitialized value in hash element at lib/coverage.perl line 85, <R> line 2596.
Use of uninitialized value in addition (+) at lib/coverage.perl line 85, <R> line 2596.
Use of uninitialized value in hash element at lib/coverage.perl line 86, <R> line 2596.
Use of uninitialized value in string ne at lib/coverage.perl line 86, <R> line 2596.
Use of uninitialized value in string ne at lib/coverage.perl line 86, <R> line 2596.
Argument "0POE/Kernel.pm" isn't numeric in addition (+) at lib/coverage.perl line 85, <R> line 3048.
Argument "0/Kernel.pm" isn't numeric in addition (+) at lib/coverage.perl line 85, <R> line 3602.
Argument "0t $line\\n";" isn't numeric in addition (+) at lib/coverage.perl line 85, <R> line 3816.
Use of uninitialized value in string ne at lib/coverage.perl line 86, <R> line 3816.
etc.

-------------------------------------------------------------------------------
