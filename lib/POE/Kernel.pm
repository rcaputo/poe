###############################################################################
# Kernel.pm - Documentation and Copyright are after __END__.
###############################################################################

package POE::Kernel;

use strict;
use POSIX;                              # for EINPROGRESS, whee!
use IO::Select;
use Carp;

use POE::Session;

#------------------------------------------------------------------------------

# states  : [ [ $session, $source_session, $state, $time, \@etc ], ... ]
#
# selects:  { $handle  => [ [ [ $r_sess, $r_state], ... ],
#                           [ [ $w_sess, $w_state], ... ],
#                           [ [ $x_sess, $x_state], ... ],
#                         ],
#           }
#
# signals:  { $signal => [ [ $session, $state ], ... ] }
#
# sessions: { $session => [ $parent, \@children, $states, $selects ] }

sub _signal_handler {
  if (defined $_[0]) {
    foreach my $kernel (@POE::Kernel::instances) {
      $kernel->_enqueue_state($kernel, $kernel, '_signal', time(), [ $_[0] ]);
    }
    $SIG{$_[0]} = \&_signal_handler;
  }
  else {
    die "undefined signal caught";
  }
}

#------------------------------------------------------------------------------

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

  my @signals = qw(ILL QUIT BREAK EMT ABRT BUS USR1 INT USR2 ALRM KILL HUP
                   PIPE SEGV TRAP TERM FPE CHLD SYS);
  foreach my $signal_name (@signals) {
    $self->{'signals'}->{$signal_name} = [ ];
    $SIG{$signal_name} = \&_signal_handler;
  }

  push(@POE::Kernel::instances, $self);

  $self->{'active session'} = $self;
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
    if (($state eq '_stop') && ($session ne $self)) {
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

    $self->{'active session'} = $session;
    $session->_invoke_state($self, $source_session, $state, $etc);

    if ($state eq '_stop') {
                                        # free lingering signals
      my @signals = $self->{'signals'};
      foreach my $signal (@signals) {
        $self->sig($signal);
      }
                                        # free lingering states (if leaking?)
      my $index = scalar(@{$self->{'states'}});
      while ($index--) {
        if ($self->{'states'}->[$index]->[0] eq $session) {
          splice(@{$self->{'states'}}, $index, 1);
        }
      }
                                        # free lingering selects
      my @handles = keys(%{$self->{'selects'}});
      foreach my $handle (@handles) {
        $self->select($handle);
      }

      if ($session eq $self) {
        $self->{'running'} = 0;
      }

      delete $self->{'sessions'}->{$session};
    }

    $self->{'active session'} = $self;

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

sub _dispatch_selects {
  my ($self, $select_handles, $selects_index) = @_;

  foreach my $handle (@$select_handles) {
    if (exists $self->{'selects'}->{$handle}) {
      my @selects = @{$self->{'selects'}->{$handle}->[$selects_index]};
      foreach my $notify (@selects) {
        my ($session, $state) = @$notify;
        $self->_dispatch_state($session, $session, $state, [ $handle ]);
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
  $self->{'running'} = 'yes';

  while (keys(%{$self->{'sessions'}})) {
                                        # SIGZOMBIE sent if no states/signals
    unless (@{$self->{'states'}} || keys(%{$self->{'selects'}})) {
      $self->_enqueue_state($self, $self, '_signal', time(), [ 'ZOMBIE' ]);
    }
                                        # select, if necessary
    my $timeout = (@{$self->{'states'}}) ?
      ($self->{'states'}->[0]->[3] - time()) : 3600;
    $timeout = 0 if ($timeout < 0);
    if ($self->{'sel_r'}->count() ||
        $self->{'sel_w'}->count() ||
        $self->{'sel_e'}->count()
    ) {
                                        # IO::Select::select doesn't clear $!
      $! = 0;
      if (my @got = IO::Select::select($self->{'sel_r'},
                                       $self->{'sel_w'},
                                       $self->{'sel_e'},
                                       $timeout)
      ) {
        scalar(@{$got[0]}) && $self->_dispatch_selects($got[0], 0);
        scalar(@{$got[1]}) && $self->_dispatch_selects($got[1], 1);
        scalar(@{$got[2]}) && $self->_dispatch_selects($got[2], 2);
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
    if (@{$self->{'states'}}) {
      if ($self->{'states'}->[0]->[3] <= time()) {
        my ($session, $source_session, $state, $time, $etc)
          = @{shift @{$self->{'states'}}};
        $self->{'sessions'}->{$session}->[2]--;
        $self->_dispatch_state($session, $source_session, $state, $etc);
      }
    }
  }
                                        # check things after all done
  print "Kernel stopped.\n";
  print "Resources leaked (if any):\n";
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
  my $active_session = $self->{'active session'};

  warn "session $session already exists"
    if (exists $self->{'sessions'}->{$session});
  
  $self->{'sessions'}->{$session} = [ $active_session, [ ], 0, 0, $session ];
  push(@{$self->{'sessions'}->{$active_session}->[1]}, $session);

  $self->_enqueue_state($session, $active_session, '_start', time(), []);
}

sub session_free {
  my ($self, $session) = @_;

  warn "session $session doesn't exist"
    unless (exists $self->{'sessions'}->{$session});

  $self->_enqueue_state($session, $self->{'active session'},
                        '_stop', time(), []
                       );
}

#------------------------------------------------------------------------------

sub alarm {
  my ($self, $state, $name, $time, @etc) = @_;
  my $active_session = $self->{'active session'};

  if ($time < (my $now = time())) {
    $time = $now;
  }

  $self->_enqueue_state($active_session, $active_session,
                        $state, $time, [ $name, @etc ]
                       );
}

#------------------------------------------------------------------------------

sub _internal_select {
  my ($self, $session, $handle, $state, $select, $select_index) = @_;
                                        # add select state
  if ($state) {
    my $written = 0;
    foreach my $notify (@{$self->{'selects'}->{$handle}->[$select_index]}) {
      if ($notify->[0] eq $session) {
        $written = 1;
        $notify->[1] = $state;
        last;
      }
    }
    unless ($written) {
      push(@{$self->{'selects'}->{$handle}->[$select_index]},
           [ $session, $state ]
          );
      $self->{'sessions'}->{$session}->[3]++;
    }
    $self->{$select}->add($handle);
  }
                                        # remove select state
  else {
    my $removed = 0;
    my $index = scalar(@{$self->{'selects'}->{$handle}->[$select_index]});
    while ($index--) {
      if ($self->{'selects'}->{$handle}->[$select_index]->[$index]->[0]
          eq $session
      ) {
        splice(@{$self->{'selects'}->{$handle}->[$select_index]},
               $index, 1
              );
        $removed = 1;
        last;
      }
    }
    if ($removed) {
      $self->{'sessions'}->{$session}->[3]--;
      $self->{$select}->remove($handle);
    }
  }
}

#------------------------------------------------------------------------------

sub select {
  my ($self, $handle, $state_r, $state_w, $state_e) = @_;
  my $active_session = $self->{'active session'};
                                        # condition the handle
  if ($state_r || $state_w || $state_e) {
    binmode($handle);
    $handle->blocking(0);
    $handle->autoflush();
  }

  unless (exists $self->{'selects'}->{$handle}) {
    $self->{'selects'}->{$handle} = [ [], [], [] ];
  }

  $self->_internal_select($active_session, $handle, $state_r, 'sel_r', 0);
  $self->_internal_select($active_session, $handle, $state_w, 'sel_w', 1);
  $self->_internal_select($active_session, $handle, $state_e, 'sel_e', 2);

  unless ($state_r || $state_w || $state_e) {
    delete $self->{'selects'}->{$handle};
  }
}

#------------------------------------------------------------------------------
# Dummy _invoke_state, so the Kernel can exist in its own 'sessions' table
# as a parent for root-level sessions.

my @_terminal_signals = qw(QUIT INT KILL HUP TERM ZOMBIE);

sub _invoke_state {
  my ($self, $kernel, $source_session, $state, $etc) = @_;
                                        # propagate signals
  if ($state eq '_signal') {
    my $signal_name = $etc->[0];

    foreach my $session (@{$self->{'signals'}->{$signal_name}}) {
      $self->_dispatch_state($session->[0], $self, $session->[1],
                             [ $signal_name ]
                            );
    }

    if (grep(/^$signal_name$/, @_terminal_signals)) {
      my @sessions = keys(%{$self->{'sessions'}});
      foreach my $session (@sessions) {
        $self->session_free($self->{'sessions'}->{$session}->[4])
      }
      $self->session_free($self);
    }
  }
}

#------------------------------------------------------------------------------

sub sig {
  my ($self, $signal, $state) = @_;
  my $active_session = $self->{'active session'};

  if ($signal) {
    my $written = 0;
    foreach my $signal (@{$self->{'signals'}->{$signal}}) {
      if ($signal->[0] eq $active_session) {
        $written = 1;
        $signal->[1] = $state;
        last;
      }
    }
    unless ($written) {
      push(@{$self->{'signals'}->{$signal}}, [ $active_session, $state ]);
    }
  }
  else {
    my $index = scalar(@{$self->{'signals'}->{$signal}});
    while ($index--) {
      if ($self->{'signals'}->{$signal}->[$index]->[0] eq $active_session) {
        splice(@{$self->{'signals'}->{$signal}}, $index, 1);
        last;
      }
    }
  }
}

#------------------------------------------------------------------------------
# Stuff for Sessions to use.

sub post_state {
  my ($self, $destination_session, $state_name, @etc) = @_;
  my $active_session = $self->{'active session'};
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
