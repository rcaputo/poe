#!perl -w -I..
# $Id$

use strict;
                                        # Kernel and Session always included
use POE;

#------------------------------------------------------------------------------
# These subs are for the ten child sessions that are created by the
# main parent.
                                        # stupid scope trick
my $session_name;
                                        # bootstrap state
sub child_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $heap->{'name'} = $session_name;
  $kernel->sig('INT', 'sigint');
  print "Session $heap->{'name'} started.\n";
}
                                        # stop stae
sub child_stop {
  my $heap = $_[HEAP];
  print "Session ", $heap->{'name'}, " stopped.\n";
}
                                        # increment a counter
sub child_increment {
  my ($kernel, $me, $heap, $name, $count) = @_[KERNEL, SELF, HEAP, ARG0, ARG1];

  $count++;

  print "Session $name, iteration $count...\n";

  my $ret = $kernel->call($me, 'display_one', $name, $count);
  print "\t(display one returns: $ret)\n";

  $ret = $kernel->call($me, 'display_two', $name, $count);
  print "\t(display two returns: $ret)\n";

  if ($count < 5) {
    $kernel->post($me, 'increment', $name, $count);
  }
}
                                        # test called states and return values
sub child_display_one {
  my ($name, $count) = @_[ARG0, ARG1];
  print "\t(display one, $name, iteration $count)\n";
  return $count * 2;
}
                                        # test called states and return values
sub child_display_two {
  my ($name, $count) = @_[ARG0, ARG1];
  print "\t(display two, $name, iteration $count)\n";
  return $count * 3;
}

#------------------------------------------------------------------------------
# These subs are for the main parent.

sub main_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # start ten sub-sessions
  foreach my $name (qw(one two three four five six seven eight nine ten)) {
    $session_name = $name;
    my $session = new POE::Session
      ( $kernel,
        _start    => \&child_start,
        _stop     => \&child_stop,
        increment => \&child_increment,
        display_one => \&child_display_one,
        display_two => \&child_display_two,
      );
                                        # tests delayed GC
    $kernel->post($session, 'increment', $name, 0);
  }
}

sub main_stop {
  print "*** Main session stopped.\n";
}

sub main_child {
  print "*** Child of main session terminated.\n";
}

#------------------------------------------------------------------------------

my $kernel = new POE::Kernel;
new POE::Session
  ( $kernel,
    _start => \&main_start,
    _stop  => \&main_stop,
    _child => \&main_child,
  );
$kernel->run();
