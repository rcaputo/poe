#!perl -w -I..
# $Id$

use strict;

use IO::File;
use POE qw(Wheel::FollowTail Driver::SysRW Filter::Line);

select(STDOUT); $|=1;

my $kernel = new POE::Kernel();

my @names;

my @numbers = qw(one two three four five six seven eight nine ten);

for my $j (0..9) {
  my $i = $numbers[$j];
  my $name = "/tmp/followtail.$$.$i";

  push @names, $name;
                                        # create a log writer
  new POE::Session
    ( $kernel,
                                        # start log file
      '_start' => sub
      { my ($k, $me) = @_; # ignoring $from
        $me->{'name'} = $name;
        $me->{'handle'} = new IO::File(">$name");
        if (defined $me->{'handle'}) {
          $k->post($me, 'activity');
        }
        else {
          print "can't open for writing $name: $!\n";
        }
      },
                                        # close and destroy log
      '_stop' => sub
      { my ($k, $me) = @_;
        if ($me->{'handle'}) {
          delete $me->{'handle'};
        }
        print "stopped writer $i\n";
      },
                                        # simulate activity, and log it
      'activity' => sub
      { my ($k, $me) = @_;
        if ($me->{'handle'}) {
          $me->{'handle'}->print("$i - ", scalar(localtime(time())), "\n");
          $me->{'handle'}->flush();
        }
        $k->alarm('activity', time() + $j+1);
      }
    );
                                        # create a log watcher
  new POE::Session
    ( $kernel,
                                        # open the log
      '_start' => sub
      { my ($k, $me) = @_; # ignoring $from here, too

        if (defined(my $handle = new IO::File("<$name"))) {
          $me->{'wheel'} = new POE::Wheel::FollowTail
            ( $kernel,
              'Handle' => $handle,
              'Driver' => new POE::Driver::SysRW(),
              'Filter' => new POE::Filter::Line(),
              'InputState' => 'got a line',
              'ErrorState' => 'error reading'
            );
        }
        else {
          print "can't open for reading $name: $!\n";
        }
      },
                                        # close the log
      '_stop' => sub
      { my ($k, $me) = @_;
        delete $me->{'wheel'};
        print "stopped reader $i\n";
      },
                                        # error?
      'error reading' => sub
      { my ($k, $me, $from, $op, $errnum, $errstr) = @_;
        print "$op error $errnum: $errstr\n";
        delete $me->{'wheel'};
      },
                                        # got a line
      'got a line' => sub
      { my ($k, $me, $from, $line) = @_;
        print "$line\n";
      },
    );
}
                                        # and to test that it's not blocking
new POE::Session
  ( $kernel,
    '_start' => sub
    { my ($k, $me) = @_;
      $k->post($me, 'spin a wheel');
    },
    'spin a wheel' => sub
    {
      my ($k, $me) = @_;
      print "*** spin! ***\n";
      $k->alarm('spin a wheel', time()+1);
    },
);

$kernel->run();
                                        # clean up temporary log files
foreach my $name (@names) {
  unlink $name;
}

exit;
