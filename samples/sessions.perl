#!perl -w -I..
# $Id$

use strict;

use POE; # Kernel and Session are always included

my $kernel = new POE::Kernel();

new POE::Session
  ( $kernel,
    '_start' => sub
    { my ($k, $me) = @_;
      new POE::Session
        ( $kernel,
          '_start' => sub
          { my ($k, $me) = @_;

            foreach my $session_name (
              qw(one two three four five six seven eight nine ten)
            ) {
              new POE::Session
                ( $kernel,
                  '_start' => sub
                  {
                    my ($k, $me, $from) = @_;
                    $me->{'name'} = $session_name;
                    $k->sig('INT', 'sigint');
                    $k->post($me, 'increment', $session_name, 0);
                    print "Session $session_name started.\n";
                  },
                  '_stop' => sub
                  {
                    my ($k, $me, $from) = @_;
                    print "Session ", $me->{'name'}, " stopped.\n";
                  },
                  '_default' => sub
                  {
                    my ($k, $me, $from, $state, @etc) = @_;
                    print $me->{'name'}, " _default got state ($state) ",
                         "from ($from) parameters (", join(', ', @etc), ")\n";
                    return 0;
                  },
                  'increment' => sub
                  {
                    my ($k, $me, $from, $session_name, $counter) = @_;
                                        # post the message first, so it's there
                    $counter++;
                    if ($counter < 5) {
                      $k->post($me, 'increment', $session_name, $counter);
                    }
                    my $ret = $k->call($me, 'display one',
                                       $session_name, $counter
                                      );
                    print "(display one returns: $ret)\n";
                    $ret = $k->call($me, 'display two',
                                    $session_name, $counter
                                   );
                    print "(display two returns: $ret)\n";
                  },
                  'display one' => sub 
                  {
                    my ($k, $me, $from, $session_name, $counter) = @_;
                    print "Session $session_name, iteration $counter (one).\n";
                    return $counter * 2;
                  },
                  'display two' => sub 
                  {
                    my ($k, $me, $from, $session_name, $counter) = @_;
                    print "Session $session_name, iteration $counter (two).\n";
                    return $counter * 3;
                  },
                );
            }
          },
          '_stop' => sub
          { my ($k, $me) = @_;
            print "*** Trunk session stopping (one-ten should be dead now)\n";
          },
          '_parent' => sub
          { my ($k, $me, $from) = @_;
            print "*** Parent changed to ($from) for trunk session ???!\n";
          },
          '_child' => sub
          { my ($k, $me, $from) = @_;
            print "*** Child of trunk session ($from) has stopped\n";
          }
        );
    },
    '_stop' => sub
    { my ($k, $me) = @_;
      print "*** Root session stopping (only kernel should be alive)\n";
    },
    '_parent' => sub
    { my ($k, $me, $from) = @_;
      print "*** Parent changed to ($from) for root session ???!\n";
    },
    '_child' => sub
    { my ($k, $me, $from) = @_;
      print "*** Child of root session ($from) has stopped\n";
    }
  );
      
$kernel->run();
