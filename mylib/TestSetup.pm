# Standard test setup things.
# $Id$

package TestSetup;

sub import {
  my $something_poorly_documented = shift;
  $ENV{PERL_DL_NONLAZY} = 0 if ($^O eq 'freebsd');
  select(STDOUT); $|=1;
  print "1..$_[0]\n";
}

1;
