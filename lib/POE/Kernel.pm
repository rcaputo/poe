###############################################################################
# Kernel.pm - Documentation and Copyright are after __END__.
###############################################################################

package POE::Kernel;

use strict;
use POSIX;                              # for EINPROGRESS
use IO::Select;


sub new {
  my $type = shift;
  my $self = bless {
                    'sessions'          => { },
                    'selects'           => { },
                    'states'            => [ ],
                    'running'           => undef,
                   }, $type;
                                        # these can't be up in the main bless?
  $self->{'sel_r'} = new IO::Select() || die $!;
  $self->{'sel_w'} = new IO::Select() || die $!;
  $self->{'sel_e'} = new IO::Select() || die $!;

  $self;
}

#------------------------------------------------------------------------------
# Send a state to a session right now.  Used by _disp_select to expedite
# select() states, and used by run() to deliver posted states from the queue.

sub _dispatch_state {
  my ($self, $session, $source_session, $state, $etc) = @_;

  my $sessions = $self->{'sessions'};

  if (exists $sessions->{$session}) {
    if (($state) eq '_parent') {
      $sessions->{$session}->[0] = $source_session;
      my $children = $sessions->{$source_session}->[1];
      @$children = grep(!/^$session$/, @$children);
    }

    $self->{'running'} = $session;
    $session->_invoke_state($self, $source_session, $state, $etc);
    $self->{'running'} = undef;

    if (($state) eq '_stop') {
      warn "session still has children" if (@{$sessions->{$session}->[1]});
      delete $sessions->{$session};
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

  while (keys(%$sessions) && (@$states || keys(%$selects))) {
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
        $self->_dispatch_state($session, $source_session, $state, $etc);
      }
    }
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

  my $states = $self->{'states'};
  if (@$states) {
    my $index = scalar(@$states);
    while ($index--) {
      if ($time >= $states->[$index]->[3]) {
        splice(@$states, $index+1, 0, $state_to_queue);
        last;
      }
      elsif (!$index) {
        splice(@$states, $index, 0, $state_to_queue);
        last;
      }
    }
  }
  else {
    $self->{'states'} = [ $state_to_queue ];
  }
}

#------------------------------------------------------------------------------

# states  : [ [ $session, $source_session, $state, $time, \@etc ], ... ]
#
# selects:  { $handle  => [ [ [ $r_sess, $r_state ], ... ],
#                           [ [ $w_sess, $w_state ], ... ],
#                           [ [ $x_sess, $x_state ], ... ],
#                         ],
#           }
#
# sessions: { $session => [ $parent, [ @children ] ] }

sub session_alloc {
  my ($self, $session) = @_;
  my $sessions = $self->{'sessions'};
  my $active_session = $self->{'running'} || warn "no active session";

  warn "session $session already exists" if (exists $sessions->{$session});

  $sessions->{$session} = [ $active_session, [ ] ];

  push(@{$sessions->{$active_session}->[1]}, $session);

  $self->_enqueue_state($session, $active_session, '_start', time(), []);
}

sub session_free {
  my ($self, $session) = @_;
  my $sessions = $self->{'sessions'};
  my $active_session = $self->{'running'} || warn "no active session";

  warn "session $session doesn't exist" unless (exists $sessions->{$session});

  my $parent_session = $sessions->{'session'}->[0];
  my @children = @{$sessions->{'session'}->[1]};
                                        # tell object it's dead
  $self->_enqueue_state($session, $active_session, '_stop', time(), []);
                                        # tell parent
  $self->_enqueue_state($parent_session, $session, '_child', time(), []);
                                        # tell children
  foreach my $child_session (@children) {
    $self->_enqueue_state(
                          $child_session, $parent_session, '_parent',
                          time(), []
                         );
  }
}

#------------------------------------------------------------------------------

#------------------------------------------------------------------------------

sub alarm {
  my ($self, $state, $name, $time, @etc) = @_;
  my $active_session = $self->{'running'} || warn "no active session";
  $self->_enqueue_state($active_session, $active_session,
                        $state, $time, $name, \@etc
                       );
}

#------------------------------------------------------------------------------

sub select {
  my ($self, $handle, $state_read, $state_write, $state_exception) = @_;
  my $selects = $self->{'selects'};
  my $active_session = $self->{'running'} || warn "no active session";

  (($state_read)
   && ($selects->{$handle}->[0]->{$active_session} = $state_read)
  ) || (delete $selects->{$handle}->[0]->{$active_session});

  (($state_write)
   && ($selects->{$handle}->[1]->{$active_session} = $state_write)
  ) || (delete $selects->{$handle}->[1]->{$active_session});

  (($state_exception) &&
   ($selects->{$handle}->[2]->{$active_session} = $state_exception)
  ) || (delete $selects->{$handle}->[2]->{$active_session});
}

#------------------------------------------------------------------------------
# Stuff for Sessions to use.

sub post_state {
  my ($self, $destination_session, $state_name, @etc) = @_;
  my $active_session = $self->{'running'} || warn "no active session";
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
