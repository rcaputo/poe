# Standard test setup things.
# $Id$

package TestSetup;

sub import {
  my $something_poorly_documented = shift;
  $ENV{PERL_DL_NONLAZY} = 0 if ($^O eq 'freebsd');
  select(STDOUT); $|=1;

  my $count = shift;
  if ($count) {
    print "1..$count\n";
  }
  else {
    my $reason = shift;
    $reason = 'no reason' unless defined $reason;
    print "1..0 # skipped: $reason\n";
    exit 0;
  }
}

1;
