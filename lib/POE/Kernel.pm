package POE::Kernel;

# POD documentation exists after __END__

my $VERSION = 1.0;
my $rcs = '$Id$';

use strict;
use POSIX qw(EINPROGRESS EINTR);
use IO::Select;
use Carp;

#------------------------------------------------------------------------------
# states  : [ [ $session, $source_session, $state, $time, \@etc ], ... ]
#
# selects:  { $handle  => [ [ [ $r_sess, $r_state], ... ],
#                           [ [ $w_sess, $w_state], ... ],
#                           [ [ $x_sess, $x_state], ... ],
#                           $handle
#                         ],
#           }
#
# signals:  { $signal => [ [ $session, $state ], ... ] }
#
# sessions: { $session => [ $parent, \@children, $states, $selects, $session,
#                           $running, $signals,
#                         ]
#           }
#------------------------------------------------------------------------------

# a list of signals that will terminate all sessions (and stop the kernel)
my @_terminal_signals = qw(QUIT INT KILL TERM ZOMBIE);

# global signal handler
sub _signal_handler {
  if (defined $_[0]) {
    foreach my $kernel (@POE::Kernel::instances) {
      $kernel->_enqueue_state($kernel, $kernel, '_signal',
                              time(), [ $_[0] ]
                             );
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
                    'signals'  => { },
                   }, $type;
                                        # these can't be up in the main bless?
  $self->{'sel_r'} = new IO::Select() || die $!;
  $self->{'sel_w'} = new IO::Select() || die $!;
  $self->{'sel_e'} = new IO::Select() || die $!;

  foreach my $signal (keys(%SIG)) {
    next if ($signal =~ /^(NUM\d+|__WARN__|__DIE__)$/);
    $SIG{$signal} = \&_signal_handler;
    $self->{'signals'}->{$signal} = [ ];
    push @{$self->{'blocked signals'}}, $signal;
  }

  push(@POE::Kernel::instances, $self);

  $self->{'active session'} = $self;

  $self->session_alloc($self);

  $self;
}

#------------------------------------------------------------------------------
# Checks the resources for a session.  If it has no queued states, and it
# has no registered selects, then the session will never again be called.
# These "zombie" sessions are culled.

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

  if ($state eq '_start') {
    $self->{'sessions'}->{$session} =
      [ $source_session, [ ], 0, 0, $session, 0, 0 ];
    push(@{$self->{'sessions'}->{$source_session}->[1]}, $session);
  }

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
      $self->{'sessions'}->{$session}->[1] = [ ];
    }
    elsif ($state eq '_start') {
      $self->{'sessions'}->{$session}->[5] = 1;
    }

    if ($self->{'sessions'}->{$session}->[5]) {
      my $hold_active_session = $self->{'active session'};
      $self->{'active session'} = $session;
      $session->_invoke_state($self, $source_session, $state, $etc);
      $self->{'active session'} = $hold_active_session;

      if ($state eq '_stop') {
        $self->{'sessions'}->{$session}->[5] = 0;
                                        # free lingering signals
        foreach my $signal (@{$self->{'blocked signals'}}) {
          $self->_internal_sig($session, $signal);
        }
                                        # free lingering states (if leaking?)
        my $index = scalar(@{$self->{'states'}});
        while ($index--) {
          if ($self->{'states'}->[$index]->[0] eq $session) {
            $self->{'sessions'}->{$session}->[2]--;
            splice(@{$self->{'states'}}, $index, 1);
          }
        }
                                        # free lingering selects
        my @handles = keys(%{$self->{'selects'}});
        foreach my $handle (@handles) {
          $self->_kernel_select($session, $self->{'selects'}->{$handle}->[3]);
        }
                                        # check for leaks -><- debugging only
        if (my $leaked = @{$self->{'sessions'}->{$session}->[1]}) {
          print "*** $session - leaking children ($leaked)\n";
        }
        if (my $leaked = $self->{'sessions'}->{$session}->[2]) {
          print "*** $session - leaking states ($leaked)\n";
        }
        if (my $leaked = $self->{'sessions'}->{$session}->[3]) {
          print "*** $session - leaking selects ($leaked)\n";
        }
        if (my $leaked = $self->{'sessions'}->{$session}->[6]) {
          print "*** $session - leaking signals ($leaked)\n";
        }

        delete $self->{'sessions'}->{$session};
      }
    }
    else {
      warn "session($session) isn't running; can't accept state($state)\n";
    }

    if (exists $self->{'sessions'}->{$session}) {
      $self->_check_session_resources($session);
    }
  }
  else {
                                        # warning because it should not happen
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
        die "select: $!" if ($! && ($! != EINPROGRESS) && ($! != EINTR));
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
                                        # buh-bye!
  print "Kernel stopped.\n";
                                        # oh, by the way...
  if (my $leaked = @{$self->{'states'}}) {
    print "*** $self - leaking states ($leaked)\n";
  }
  if (my $leaked = keys(%{$self->{'selects'}})) {
    print "*** $self - leaking selects ($leaked)\n";
  }
  if (my $leaked = keys(%{$self->{'sessions'}})) {
    print "*** $self - leaking sessions ($leaked)\n";
  }
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

#  $self->{'sessions'}->{$session} =
#    [ $active_session, [ ], 0, 0, $session, 0 ];
#  push(@{$self->{'sessions'}->{$active_session}->[1]}, $session);
#
#  $self->_enqueue_state($session, $active_session, '_start', time(), []);

  $self->_dispatch_state($session, $active_session, '_start', []);
  $self->{'active session'} = $active_session;
}

sub session_free {
  my ($self, $session) = @_;

  warn "session $session doesn't exist"
    unless (exists $self->{'sessions'}->{$session});

  $self->_dispatch_state($session, $self->{'active session'}, '_stop', []);

#  $self->_enqueue_state($session, $self->{'active session'},
#                        '_stop', time(), []
#                       );
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

sub _maybe_add_handle {
  my ($self, $handle) = @_;

  unless (exists $self->{'selects'}->{$handle}) {
    $self->{'selects'}->{$handle} = [ [], [], [], $handle ];
    binmode($handle);
    $handle->blocking(0);
    $handle->autoflush();
  }
}

sub _maybe_remove_handle {
  my ($self, $handle) = @_;

  unless (@{$self->{'selects'}->{$handle}->[0]} ||
          @{$self->{'selects'}->{$handle}->[1]} ||
          @{$self->{'selects'}->{$handle}->[2]}
  ) {
    delete $self->{'selects'}->{$handle};
  }
}

#------------------------------------------------------------------------------

sub _kernel_select {
  my ($self, $session, $handle, $state_r, $state_w, $state_e) = @_;
  $self->_maybe_add_handle($handle);
  $self->_internal_select($session, $handle, $state_r, 'sel_r', 0);
  $self->_internal_select($session, $handle, $state_w, 'sel_w', 1);
  $self->_internal_select($session, $handle, $state_e, 'sel_e', 2);
  $self->_maybe_remove_handle($handle);
}

#------------------------------------------------------------------------------
# Dummy _invoke_state, so the Kernel can exist in its own 'sessions' table
# as a parent for root-level sessions.

sub _invoke_state {
  my ($self, $kernel, $source_session, $state, $etc) = @_;
                                        # propagate signals
  if ($state eq '_signal') {
    my $signal_name = $etc->[0];

    if ($signal_name eq 'ZOMBIE') {
      print "Kernel caught SIGZOMBIE.\n";
    }

    foreach my $session (@{$self->{'signals'}->{$signal_name}}) {
      $self->_dispatch_state($session->[0], $self, $session->[1],
                             [ $signal_name ]
                            );
    }

    if (grep(/^$signal_name$/, @_terminal_signals)) {
      my @sessions = keys(%{$self->{'sessions'}});
      foreach my $session (@sessions) {
        next if ($session eq $self);
        $self->session_free($self->{'sessions'}->{$session}->[4])
      }
      $self->session_free($self);
    }
  }
}

#------------------------------------------------------------------------------

sub _internal_sig {
  my ($self, $session, $signal, $state) = @_;

  if ($state) {
    my $written = 0;
    foreach my $signal (@{$self->{'signals'}->{$signal}}) {
      if ($signal->[0] eq $session) {
        $written = 1;
        $signal->[1] = $state;
        last;
      }
    }
    unless ($written) {
      push(@{$self->{'signals'}->{$signal}}, [ $session, $state ]);
      $self->{'sessions'}->{$session}->[6]++;
    }
  }
  else {
    my $index = scalar(@{$self->{'signals'}->{$signal}});
    while ($index--) {
      if ($self->{'signals'}->{$signal}->[$index]->[0] eq $session) {
        splice(@{$self->{'signals'}->{$signal}}, $index, 1);
        $self->{'sessions'}->{$session}->[6]--;
        last;
      }
    }
  }
}

#------------------------------------------------------------------------------
# Alarm management.

sub alarm {
  my ($self, $state, $time, @etc) = @_;
  my $active_session = $self->{'active session'};
                                        # remove alarm (all instances)
  my $index = scalar(@{$self->{'states'}});
  while ($index--) {
    if (($self->{'states'}->[$index]->[0] eq $active_session) &&
        ($self->{'states'}->[$index]->[2] eq $state)
    ) {
      $self->{'sessions'}->{$active_session}->[2]--;
      splice(@{$self->{'states'}}, $index, 1);
    }
  }
                                        # add alarm (if non-zero time)
  if ($time) {
    if ($time < (my $now = time())) {
      $time = $now;
    }
    $self->_enqueue_state($active_session, $active_session,
                          $state, $time, [ @etc ]
                         );
  }
}

#------------------------------------------------------------------------------
# Select management.

sub select {
  my ($self, $handle, $state_r, $state_w, $state_e) = @_;

  $self->_kernel_select($self->{'active session'}, $handle,
                        $state_r, $state_w, $state_e
                       );
}

sub select_read {
  my ($self, $handle, $state) = @_;
  $self->_maybe_add_handle($handle);
  $self->_internal_select($self->{'active session'},
                          $handle, $state, 'sel_r', 0
                         );
  $self->_maybe_remove_handle($handle);
};

sub select_write {
  my ($self, $handle, $state) = @_;
  $self->_maybe_add_handle($handle);
  $self->_internal_select($self->{'active session'},
                          $handle, $state, 'sel_w', 1
                         );
  $self->_maybe_remove_handle($handle);
};

sub select_exception {
  my ($self, $handle, $state) = @_;
  $self->_maybe_add_handle($handle);
  $self->_internal_select($self->{'active session'},
                          $handle, $state, 'sel_e', 2
                         );
  $self->_maybe_remove_handle($handle);
};

#------------------------------------------------------------------------------
# Signal management.

sub sig {
  my ($self, $signal, $state) = @_;
  $self->_internal_sig($self->{'active session'}, $signal, $state);
}

#------------------------------------------------------------------------------
# Post a state to the queue.

sub post {
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

#------------------------------------------------------------------------------
# State management.

sub state {
  my ($self, $state_name, $state_code) = @_;
  my $active_session = $self->{'active session'};
                                        # invoke the session's
  $active_session->register_state($state_name, $state_code);
}

###############################################################################
1;
__END__

=head1 NAME

POE::Kernel - manage events, selects and signals for C<POE::Session> instances

=head1 SYNOPSIS

  use POE::Kernel;
  use POE::Session;

  $kernel = new POE::Kernel;

  new POE::Session(...);   # one or more starting sessions

  $kernel->run();          # run sessions; serve events, selects, signals
  exit;

=head1 DESCRIPTION

C<POE::Kernel> in a nutshell.

=over 2

=item *

It queues and delivers events to instances of C<POE::Session>.  Alarms
are implemented as delayed events.

=item *

It offers select(2) services for files based on IO::Handle.  They are
implemented as immediate events, allowing sessions to bypass the queue
entirely.

=item *

It catches signals and passes them as events to C<POE::Session> instances.

=item *

It allows sessions to modify their event handlers.  Extensions add and
remove features by altering code in the caller.

=back

=head1 PUBLIC METHODS

=over 4

=item new POE::Kernel;

Creates a self-contained C<POE::Kernel> object, and returns a reference
to it.  (Untested:  It should be possible to run one Kernel per thread.)

=item $kernel->run()

Starts the kernel, and will not return until all its C<POE::Session>
instances have completed.

=item $kernel->select($handle, $state_r, $state_w, $state_e)

Manages read, write and exception bits for a C<IO::Handle> object owned by
the currently active C<POE::Session>.  Defined states are added, and
undefined ones are removed.  When select(2) unblocks, the named event
handlers (states) are invoked with C<$handle> to take care of file activity.

=item $kernel->select_read($handle, $state)

Manages just the "read" select(2) vector for a C<$handle> owned by the
currently active C<POE::Session>.  Works like 1/3 of C<$kernel->select()>.

=item $kernel->select_write($handle, $state)

Manages just the "write" select(2) vector for a C<$handle> owned by the
currently active C<POE::Session>.  Works like 1/3 of C<$kernel->select()>.

=item $kernel->select_exception($handle, $state)

Manages just the "exception" select(2) vector for a C<$handle>. owned by the
currently active C<POE::Session>.  Works like 1/3 of C<$kernel->select()>.

=item $kernel->sig($signal, $state)

Add or remove an event handler for the signal named in C<$signal}> (same
names as with C<%SIG>).  If C<$state> is defined, then that state will be
invoked when a specified signal.  If C<$state> is undefined, then the
C<$SIG{$signal}> handler is removed.

=item $kernel->post($destination_session, $state_name, @etc)

Enqueues an event (C<$state>) for the C<$destination_session>.  Additional
parameters (C<@etc>) can be passed along.

=item $kernel->state($state_name, $state_code)

Registers a CODE reference (C<$state_code>) for the event C<$state_name> in
the currently active C<POE::Session>.  If C<$state_code> is undefined, then
the named state will be removed.

=back

=head1 PROTECTED METHODS

Not for general use.

=over 4

=item $kernel->session_alloc($session)

Enqueues a C<_start> event for a session.  The session is added to the
kernel just before the event is dispatched.

=item $kernel->session_free($session)

Enqueues a C<_stop> event for a session.  The kernel will deallocate and
destroy the session and all its related resources after C<_stop> has been
dispatched to the session.

=back

=head1 PRIVATE METHODS

Not for general use.

=over 4

=item DESTROY

Destroy the Kernel, and all associated resources.  Nothing implemented yet.

=item _signal_handler

Registered as a handle for allmost all the signals in %SIG.  It enqueues
C<_signal> events for every active C<POE::Kernel>.  The kernels relay
C<_signal> events to every C<POE::Session> registered for them.

=item $kernel->_check_session_resources($session)

Called after an event has been dispatched.  This function stops sessions
that have run out of things to do.

=item $kernel->_dispatch_state($session, $source_session, $state, \@etc)

Immediately dispatches an event (state transition) from a source session
to a destination session.  C<\@etc> is an optional array reference that
holds additional information that the session expects.

=item $kernel->_dispatch_selects($select_handles, $selects_index)

This helper checks C<IO::Select> objects for activity.  It uses
C<_dispatch_state> to notify C<POE::Session> instances immediately.

=item $kernel->_enqueue_state($session, $source_session, $state, $time, \@etc)

Combines the parameters into an event (state transition), and enqueues it
to be delivered at a particular time.  Alarms are implemented as events that
are scheduled to happen at a future time.

C<$time> is clipped to C<time()>.

=item $kernel->_internal_select($session, $handle, $state, $select, $select_index)

The guts of select(2) management.  Registers or removes a select bit for
C<IO::Handle>.  When select unblocks, an event (C<$state>) will be immediately
dispatched to C<$session>, along with the C<$handle> so it can be taken care
of.

=item $kernel->_maybe_add_handle($handle)

Register a handle resource (C<$handle>) with this kernel, if one is not
already there.

=item $kernel->_maybe_remove_handle($handle)

Remove a handle resource (C<$handle>) from this kernel, if one exists.

=item $kernel->_kernel_select($session, $handle, $state_r, $state_w, $state_e)

Register or remove read, write and exception states for a handle all at once.

=back

=head1 EXAMPLES

Please see the tests directory that comes with the POE bundle.

=head1 BUGS

DESTROY is not implemented.  This has not been a problem so far.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
