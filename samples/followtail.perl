#!/usr/bin/perl -w
# $Id$

# This program tests Wheel::FollowTail.  The FollowTail wheel provides
# a reusable "tail -f" behavior for drivers and filters.

# NOTE: sessions.perl, objsessions.perl, and packagesessions.perl have
# better comments for the basic stuff.

use strict;
use lib '..';
use POE qw(Wheel::FollowTail Driver::SysRW Filter::Line Wheel::ReadWrite);
use IO::File;

#==============================================================================
                                        # used to keep track of file names
my @names;
                                        # the names of sessions to create
my @numbers = qw(one two three four five six seven eight nine ten);

#------------------------------------------------------------------------------
# Create twenty sessions: ten log generators and ten log followers.
# The generators periodically write a line of information to their
# respective logs.  The followers detect that the logs have new
# information and display it.

for my $j (0..9) {
                                        # call the sessions by name
  my $i = $numbers[$j];
                                        # create temporary filenames
  my $name = "/tmp/followtail.$$.$i";
                                        # track the names for later cleanup
  push @names, $name;
                                        ### create a log writer
  new POE::Session
    ( '_start' => sub
      { my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
                                        # save my ID
        $heap->{'id'} = $i;
                                        # create the "log" file
        my $handle = new IO::File(">$name");
        if (defined $handle) {
                                        # create non-blocking write-only wheel
          $heap->{'wheel'} = new POE::Wheel::ReadWrite
            ( Handle     => $handle,                  # using this handle
              Driver     => new POE::Driver::SysRW(), # using syswrite
              Filter     => new POE::Filter::Line(),  # write lines
              ErrorState => 'log_error'               # acknowledge errors
            );

          $kernel->post($session, 'activity');
        }
        else {
          print "Writer $heap->{'id'} can't open $name for writing: $!\n";
        }
      },
                                        # acknowledge errors; perhaps disk full
      'log_error' => sub
      { my ($heap, $op, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
        print "Writer $heap->{'id'} encountered $op error $errnum: $errstr\n";
        delete $heap->{'wheel'};
      },
                                        # close and destroy the log filehandle
      '_stop' => sub
      { my $heap = $_[HEAP];
        delete $heap->{'wheel'};
        print "Writer $heap->{'id'} has stopped.\n";
      },
                                        # simulate activity, and log it
      'activity' => sub
      { my ($kernel, $heap) = @_[KERNEL, HEAP];
                                        # only if it still has the file open
        if ($heap->{'wheel'}) {
                                        # write a timestamp
          $heap->{'wheel'}->put($heap->{'id'} . ' - ' .
                                scalar(localtime(time()))
                               );
        }
                                        # generate more activity after a delay
        $kernel->delay('activity', $j+1);
      }
    );
                                        ### create a log follower
  new POE::Session
    ( '_start' => sub
      { my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
        $heap->{'id'} = $i;
                                        # try to open the file
        if (defined(my $handle = new IO::File("<$name"))) {
                                        # start following the file's tail
          $heap->{'wheel'} = new POE::Wheel::FollowTail
            ( 'Handle' => $handle,                  # follow this handle
              'Driver' => new POE::Driver::SysRW(), # use sysread to read
              'Filter' => new POE::Filter::Line(),  # file contains lines
              'InputState' => 'got a line',         # input handler
              'ErrorState' => 'error reading',      # error handler
              'PollInterval' => 2,
            );
        }
                                        # could not read the file
        else {
          print "Reader $heap->{'id'} can't open $name for reading: $!\n";
        }
      },
                                        # close and destroy the log filehandle
      '_stop' => sub
      { my $heap = $_[HEAP];
        delete $heap->{'wheel'};
        print "Reader $heap->{'id'} has stopped.\n";
      },
                                        # error handler
      'error reading' => sub
      { my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
        print( "Reader ",$heap->{'id'},
               " encountered $operation error $errnum: $errstr.\n"
             );
                                        # removes the session's purpose to live
        delete $heap->{'wheel'};
      },
                                        # input handler
      'got a line' => sub
      { my $line_of_input = $_[ARG0];
                                        # just display the input
        print $line_of_input, "\n";
      },
    );
}

#------------------------------------------------------------------------------
# This session is just a busy loop that prints a message every half
# second.  It does this to ensure that the other twenty sessions are
# not blocking while waiting for input.

new POE::Session
  ( '_start' => sub
    { my ($kernel, $session) = @_[KERNEL, SESSION];
      $kernel->post($session, 'spin a wheel');
    },
    'spin a wheel' => sub
    { my $kernel = $_[KERNEL];
      print "*** spin! ***\n";
      $kernel->delay('spin a wheel', 0.5);
    },
);

#==============================================================================
# Run the kernel until all the sessions die (SIGINT, most likely).
# When done, unlink the temporary files in @names.

$poe_kernel->run();

# The temporary files are unlinked out here because some systems
# (notably DOSISH ones) don't allow files to be unlinked while they
# are open.

unlink @names;

exit;
