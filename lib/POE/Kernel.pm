###############################################################################
# Kernel.pm - Documentation and Copyright are after __END__.
###############################################################################

package POE::Kernel;

use strict;
use POSIX;                              # for EINPROGRESS, whee!
use IO::Select;
use Carp;

use POE::Session;

# states  : [ [ $session, $source_session, $state, $time, \@etc ], ... ]
#
# selects:  { $handle  => [ [ [ $r_sess, $r_state ], ... ],
#                           [ [ $w_sess, $w_state ], ... ],
#                           [ [ $x_sess, $x_state ], ... ],
#                         ],
#           }
#
# sessions: { $session => [ $parent, \@children, $states, $selects ] }

sub new {
  my $type = shift;
  my $self = bless {
                    'sessions' => { },
                    'selects'  => { },
                    'states'   => [ ],
                   }, $type;
                                        # these can't be up in the main bless?
  $self->{'sel_r'} = new IO::Select() || die $!;
  $self->{'sel_w'} = new IO::Select() || die $!;
  $self->{'sel_e'} = new IO::Select() || die $!;

  $self->{'running'} = $self;
  $self->session_alloc($self);

  $self;
}

#------------------------------------------------------------------------------
# Checks the resources for a session.  If it has no queued states, and it
# has no registered selects, then the session will never again be called.
# These "zombie" sessions need to be culled.

sub _check_session_resources {
  my ($self, $session) = @_;

  if ($session ne $self) {
    unless ($self->{'sessions'}->{$session}->[2] ||
            $self->{'sessions'}->{$session}->[3]
    ) {
      $self->session_free($session);
    }
  }
}

#------------------------------------------------------------------------------
# Send a state to a session right now.  Used by _disp_select to expedite
# select() states, and used by run() to deliver posted states from the queue.

sub _dispatch_state {
  my ($self, $session, $source_session, $state, $etc) = @_;
  if (exists $self->{'sessions'}->{$session}) {
    if ($state eq '_stop') {
                                        # remove the session from its parent
      my $old_parent = $self->{'sessions'}->{$session}->[0];
      if (exists $self->{'sessions'}->{$old_parent}) {
        my $regexp = quotemeta($session);
        @{$self->{'sessions'}->{$old_parent}->[1]} =
          grep(!/^$regexp$/, @{$self->{'sessions'}->{$old_parent}->[1]});
      }
      else {
        warn "state($state)  old parent($old_parent) nonexistent";
      }
                                        # tell the parent its child is gone
      $self->_dispatch_state($old_parent, $session, '_child', []);
                                        # give custody of kid sto new parent
      foreach my $child_session (@{$self->{'sessions'}->{$session}->[1]}) {
        $self->{'sessions'}->{$child_session}->[0] = $old_parent;
        push(@{$self->{'sessions'}->{$old_parent}->[1]}, $child_session);
        $self->_dispatch_state($child_session, $old_parent, '_parent', []);
      }
    }

    $self->{'running'} = $session;
    $session->_invoke_state($self, $source_session, $state, $etc);
    $self->{'running'} = $self;

    if ($state eq '_stop') {
      delete $self->{'sessions'}->{$session};
    }

    if (exists $self->{'sessions'}->{$session}) {
      $self->_check_session_resources($session);
    }
  }
  else {
    warn "session($session) does not exist - state($state) not dispatched";
  }
}

#------------------------------------------------------------------------------
# Immediately call sessions' registered select states.  The called states
# should read or write from the selected filehandle so that select won't
# re-trigger immediately (unless that's okay by the session).

sub _dispatch_select {
  my ($self, $select_handles, $selects, $selects_index) = @_;
  foreach my $handle (@$select_handles) {
    if (exists $selects->{$handle}) {
      foreach my $notify (@{$selects->{$handle}->[$selects_index]}) {
        my ($session, $state) = @$notify;
        $self->_dispatch_state($session, $session, $state, []);
      }
    }
    else {
      warn "select index($selects_index) does not have handle($handle)";
    }
  }
}

#------------------------------------------------------------------------------

sub run {
  my $self = shift;
  my ($sessions, $selects, $states, $sel_r, $sel_w, $sel_e) =
    @$self{qw(sessions selects states sel_r sel_w sel_e)};

  while (@$states || keys(%$selects)) {
                                        # select, if necessary
    my $timeout = (@$states) ? ($states->[0]->[3] - time()) : 60;
    $timeout = 0 if ($timeout < 0);
    if ($sel_r->count() || $sel_w->count() || $sel_e->count()) {
      if (my @got = IO::Select::select($sel_r, $sel_w, $sel_e, $timeout)) {
        scalar(@{$got[0]}) && $self->_dispatch_selects($got[0], $selects, 0);
        scalar(@{$got[1]}) && $self->_dispatch_selects($got[1], $selects, 1);
        scalar(@{$got[2]}) && $self->_dispatch_selects($got[2], $selects, 2);
      }
      else {
        die "select: $!" if ($! && ($! != EINPROGRESS));
      }
    }
                                        # otherwise, sleep until next event
    elsif ($timeout) {
      sleep($timeout);
    }
                                        # dispatch queued events
    if (@$states) {
      if ($states->[0]->[3] <= time()) {
        my ($session, $source_session, $state, $time, $etc)
          = @{shift @$states};
        $sessions->{$session}->[2]--;
        $self->_dispatch_state($session, $source_session, $state, $etc);
      }
    }
  }
                                        # check things after all done
  print "*** End stats (tests garbage collection):\n";
  print "states  : ", scalar(@{$self->{'states'}}), "\n";
  print "selects : ", scalar(keys %{$self->{'selects'}}), "\n";
  print "sessions: ", scalar(keys %{$self->{'sessions'}}), "\n";
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  # destroy all sessions - will cascade destruction to all resources
}

#------------------------------------------------------------------------------

sub _enqueue_state {
  my ($self, $session, $source_session, $state, $time, $etc) = @_;
  my $state_to_queue = [ $session, $source_session, $state, $time, $etc ];

  if (exists $self->{'sessions'}->{$session}) {
    if (@{$self->{'states'}}) {
      my $index = scalar(@{$self->{'states'}});
      while ($index--) {
        if ($time >= $self->{'states'}->[$index]->[3]) {
          splice(@{$self->{'states'}}, $index+1, 0, $state_to_queue);
          last;
        }
        elsif (!$index) {
          splice(@{$self->{'states'}}, $index, 0, $state_to_queue);
          last;
        }
      }
    }
    else {
      @{$self->{'states'}} = ($state_to_queue);
    }
    $self->{'sessions'}->{$session}->[2]++;
  }
  else {
    carp "can't enqueue state($state) for nonexistent session($session)";
  }
}

#------------------------------------------------------------------------------

sub session_alloc {
  my ($self, $session) = @_;
  my $sessions = $self->{'sessions'};
  my $active_session = $self->{'running'};

  warn "session $session already exists" if (exists $sessions->{$session});
  
  $sessions->{$session} = [ $active_session, [ ], 0, 0 ];
  push(@{$sessions->{$active_session}->[1]}, $session);

#  $self->_dispatch_state($session, $active_session, '_start', []);
  $self->_enqueue_state($session, $active_session, '_start', time(), []);
}

sub session_free {
  my ($self, $session) = @_;
  my $sessions = $self->{'sessions'};
  my $active_session = $self->{'running'};

  warn "session $session doesn't exist" unless (exists $sessions->{$session});

#  $self->_dispatch_state($session, $active_session, '_stop', []);
  $self->_enqueue_state($session, $active_session, '_stop', time(), []);
}

#------------------------------------------------------------------------------

sub alarm {
  my ($self, $state, $name, $time, @etc) = @_;
  my $active_session = $self->{'running'};
  $self->_enqueue_state($active_session, $active_session,
                        $state, $time, $name, \@etc
                       );
}

#------------------------------------------------------------------------------

sub select {
  my ($self, $handle, $state_read, $state_write, $state_exception) = @_;
  my $selects = $self->{'selects'};
  my $sessions = $self->{'sessions'};
  my $active_session = $self->{'running'};

  $handle->binmode(1);
  $handle->blocking(0);
  $handle->autoflush();

  if ($state_read) {
    if (exists $selects->{$handle}->[0]->{$active_session}) {
      carp "redefining session($active_session), read state";
    }
    else {
      $sessions->{$active_session}->[3]++;
    }
    $selects->{$handle}->[0]->{$active_session} = $state_read;
  }
  else {
    if (exists $selects->{$handle}->[0]->{$active_session}) {
      $sessions->{$active_session}->[3]--;
    }
    delete $selects->{$handle}->[0]->{$active_session};
  }

  if ($state_write) {
    if (exists $selects->{$handle}->[1]->{$active_session}) {
      carp "redefining session($active_session), write state";
    }
    else {
      $sessions->{$active_session}->[3]++;
    }
    $selects->{$handle}->[1]->{$active_session} = $state_read;
  }
  else {
    if (exists $selects->{$handle}->[1]->{$active_session}) {
      $sessions->{$active_session}->[3]--;
    }
    delete $selects->{$handle}->[1]->{$active_session};
  }

  if ($state_exception) {
    if (exists $selects->{$handle}->[2]->{$active_session}) {
      carp "redefining session($active_session), exception state";
    }
    else {
      $sessions->{$active_session}->[3]++;
    }
    $selects->{$handle}->[2]->{$active_session} = $state_exception;
  }
  else {
    if (exists $selects->{$handle}->[2]->{$active_session}) {
      $sessions->{$active_session}->[3]--;
    }
    delete $selects->{$handle}->[2]->{$active_session};
  }
}

#------------------------------------------------------------------------------
# Dummy _invoke_state, so the Kernel can exist in its own 'sessions' table
# as a parent for root-level sessions.

sub _invoke_state {
  my ($self, $kernel, $source_session, $state, $etc) = @_;
  # print "kernel caught state($state)\n";
}

#------------------------------------------------------------------------------
# Stuff for Sessions to use.

sub post_state {
  my ($self, $destination_session, $state_name, @etc) = @_;
  my $active_session = $self->{'running'};
                                        # external -> internal representation
  if ($destination_session eq $active_session->{'namespace'}) {
    $destination_session = $active_session;
  }

  $self->_enqueue_state($destination_session, $active_session,
                        $state_name, time(), \@etc
                       );
}

###############################################################################
1;
__END__

Documentation: to be

Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
This is a pre-release version.  Redistribution and modification are
prohibited.
