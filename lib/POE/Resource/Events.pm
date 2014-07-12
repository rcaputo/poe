# Data and accessors to manage POE's events.

package POE::Resource::Events;

use vars qw($VERSION);
$VERSION = '1.364'; # NOTE - Should be #.### (three decimal places)

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

# A local copy of the queue so we can manipulate it directly.
my $kr_queue;

my %event_count;
#  ( $session_id => $count,
#    ...,
#  );

my %post_count;
#  ( $session_id => $count,
#    ...,
#  );

### Begin-run initialization.

sub _data_ev_initialize {
  my ($self, $queue) = @_;
  $kr_queue = $queue;
}

### End-run leak checking.

sub _data_ev_relocate_kernel_id {
  my ($self, $old_id, $new_id) = @_;

  $event_count{$new_id} = delete $event_count{$old_id}
    if exists $event_count{$old_id};
  $post_count{$new_id} = delete $post_count{$old_id}
    if exists $post_count{$old_id};
}

sub _data_ev_finalize {
  my $finalized_ok = 1;
  while (my ($ses_id, $cnt) = each(%event_count)) {
    $finalized_ok = 0;
    _warn("!!! Leaked event-to count: $ses_id = $cnt\n");
  }

  while (my ($ses_id, $cnt) = each(%post_count)) {
    $finalized_ok = 0;
    _warn("!!! Leaked event-from count: $ses_id = $cnt\n");
  }
  return $finalized_ok;
}

### Enqueue an event.

sub FIFO_TIME_EPSILON () { 0.000001 }
my $last_fifo_time = monotime();

sub _data_ev_enqueue {
  my (
    $self,
    $session, $source_session, $event, $type, $etc,
    $file, $line, $fromstate, $time, $delta, $priority
  ) = @_;

  my $sid = $session->ID;

  if (ASSERT_DATA) {
    unless ($self->_data_ses_exists($sid)) {
      _trap(
        "<ev> can't enqueue event ``$event'' for nonexistent",
        $self->_data_alias_loggable($sid)
      );
    }
  }

  # This is awkward, but faster than using the fields individually.
  my $event_to_enqueue = [ @_[(1+EV_SESSION) .. (1+EV_FROMSTATE)] ];
  if( defined $time ) {
    $event_to_enqueue->[EV_WALLTIME] = $time;
    $event_to_enqueue->[EV_DELTA]    = $delta;
    $priority ||= wall2mono( $time + ($delta||0) );
  }
  else {
    $priority ||= monotime();
  }

  my $new_id;
  my $old_head_priority = $kr_queue->get_next_priority();

  unless ($type & ET_MASK_DELAYED) {
    $priority = $last_fifo_time + FIFO_TIME_EPSILON if $priority <= $last_fifo_time;
    $last_fifo_time = $priority;
  }

  $new_id = $kr_queue->enqueue($priority, $event_to_enqueue);
  $event_to_enqueue->[EV_SEQ] = $new_id;

  #_carp( Carp::longmess( "<ev> priority is much to far in the future" ) ) if $priority > 1354569908;
  if (TRACE_EVENTS ) {
    _warn(
      "<ev> enqueued event $new_id ``$event'' from ",
      $self->_data_alias_loggable($source_session->ID), " to ",
      $self->_data_alias_loggable($sid),
      " at $time, priority=$priority"
    );
  }

  unless (defined $old_head_priority) {
    $self->loop_resume_time_watcher($priority);
  }
  elsif ($priority < $old_head_priority) {
    $self->loop_reset_time_watcher($priority);
  }

  # This is the counterpart to _data_ev_refcount_dec().  It's only
  # used in one place, so it's not in its own function.

  $self->_data_ses_refcount_inc($sid) unless $event_count{$sid}++;

  return $new_id if $sid eq $source_session->ID();

  $self->_data_ses_refcount_inc($source_session->ID) unless (
    $post_count{$source_session->ID}++
  );

  return $new_id;
}

sub _data_ev_set
{
    my( $self, $alarm_id, $my_alarm, $time, $pri, $delta ) = @_;

    my $event = (
      grep { $_->[1] == $alarm_id }
      $kr_queue->peek_items( $my_alarm )
    )[0];

    return unless $event;

    my $payload = $event->[ITEM_PAYLOAD];

    # XXX - However, if there has been a clock skew, the priority will
    # have changed and we should recalculate priority from time+delta

    $delta = $payload->[EV_DELTA] || 0 unless defined $delta;
    $kr_queue->set_priority( $alarm_id, $my_alarm, $pri+$delta );
    $payload->[EV_WALLTIME] = $time;
    $payload->[EV_DELTA]    = $delta;

    return( ($payload->[EV_WALLTIME] || 0) + ($payload->[EV_DELTA] || 0) );
}

sub _data_ev_adjust
{
    my( $self, $alarm_id, $my_alarm, $time, $delta ) = @_;

    # XXX - However, if there has been a clock skew, the priority will
    # have changed and we should recalculate priority from time+delta
    if( $time ) {
        # PG - We are never invoked with $time anyway.  
        $kr_queue->set_priority( $alarm_id, $my_alarm, $time+$delta );
    }
    else {
        $kr_queue->adjust_priority( $alarm_id, $my_alarm, $delta );
    }

    my $event = (
      grep { $_->[1] == $alarm_id }
      $kr_queue->peek_items( $my_alarm )
    )[0];

    return unless $event;

    my $payload = $event->[ITEM_PAYLOAD];

    $payload->[EV_WALLTIME] = $time if $time;
    $payload->[EV_DELTA] += $delta  if $delta;

    return( ($payload->[EV_WALLTIME] || 0) + ($payload->[EV_DELTA] || 0) );
}

### Remove events sent to or from a specific session.

sub _data_ev_clear_session {
  my ($self, $sid) = @_;

  # Events sent to the session.
  PENDING: {
    my $pending_count = $event_count{$sid};
    last PENDING unless $pending_count;

    foreach (
      $kr_queue->remove_items(
        sub { $_[0][EV_SESSION]->ID() eq $sid },
        $pending_count
      )
    ) {
      $self->_data_ev_refcount_dec(
        @{$_->[ITEM_PAYLOAD]}[EV_SOURCE, EV_SESSION]
      );
      $pending_count--;
    }

    # TODO - fork() can make this go negative on some systems.
    last PENDING unless $pending_count;

    croak "lingering pending count: $pending_count" if $pending_count;
  }

  # Events sent by the session.
  SENT: {
    my $sent_count = $post_count{$sid};
    last SENT unless $sent_count;

    foreach (
      $kr_queue->remove_items(
        sub { $_[0][EV_SOURCE]->ID() eq $sid },
        $sent_count
      )
    ) {
      $self->_data_ev_refcount_dec(
        @{$_->[ITEM_PAYLOAD]}[EV_SOURCE, EV_SESSION]
      );
      $sent_count--;
    }

    last SENT unless $sent_count;

    croak "lingering sent count: $sent_count" if $sent_count;
  }

  croak "lingering event count" if delete $event_count{$sid};
  croak "lingering post count" if delete $post_count{$sid};
}

# TODO Alarm maintenance functions may move out to a separate
# POE::Resource module in the future.  Why?  Because alarms may
# eventually be managed by something other than the event queue.
# Especially if we incorporate a proper Session scheduler.  Be sure to
# move the tests to a corresponding t/res/*.t file.

### Remove a specific alarm by its name.  This is in the events
### section because alarms are currently implemented as events with
### future due times.

sub _data_ev_clear_alarm_by_name {
  my ($self, $sid, $alarm_name) = @_;

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION]->ID() eq $sid;
    return 0 unless $_[0]->[EV_NAME] eq $alarm_name;
    return 1;
  };

  foreach ($kr_queue->remove_items($my_alarm)) {
    $self->_data_ev_refcount_dec(@{$_->[ITEM_PAYLOAD]}[EV_SOURCE, EV_SESSION]);
  }
}

### Remove a specific alarm by its ID.  This is in the events section
### because alarms are currently implemented as events with future due
### times.  TODO It's possible to remove non-alarms; is that wrong?

sub _data_ev_clear_alarm_by_id {
  my ($self, $sid, $alarm_id) = @_;

  my $my_alarm = sub {
    $_[0]->[EV_SESSION]->ID() eq $sid;
  };

  my ($pri, $id, $event) = $kr_queue->remove_item($alarm_id, $my_alarm);
  return unless defined $pri;

  if (TRACE_EVENTS) {
    _warn(
      "<ev> removed event $id ``", $event->[EV_NAME], "'' to ",
      $self->_data_alias_loggable($sid), " at $pri"
    );
  }

  $self->_data_ev_refcount_dec( @$event[EV_SOURCE, EV_SESSION] );
  my $time = $event->[EV_WALLTIME] + ($event->[EV_DELTA]||0);
  return ($time, $event);
}

### Remove all the alarms for a session.  Whoot!

sub _data_ev_clear_alarm_by_session {
  my ($self, $sid) = @_;

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION]->ID() eq $sid;
    return 1;
  };

  my @removed;
  foreach ($kr_queue->remove_items($my_alarm)) {
    my ($pri, $event) = @$_[ITEM_PRIORITY, ITEM_PAYLOAD];
    $self->_data_ev_refcount_dec( @$event[EV_SOURCE, EV_SESSION] );
    my $time = ($event->[EV_WALLTIME]||0) + ($event->[EV_DELTA]||0);
    push @removed, [ $event->[EV_NAME], $time, @{$event->[EV_ARGS]} ];
  }

  return @removed;
}

### Decrement a post refcount

sub _data_ev_refcount_dec {
  my ($self, $source_session, $dest_session) = @_;

  my ($source_id, $dest_id) = ($source_session->ID, $dest_session->ID);

  if (ASSERT_DATA) {
    _trap $dest_session unless exists $event_count{$dest_id};
  }

  $self->_data_ses_refcount_dec($dest_id) unless --$event_count{$dest_id};

  return if $dest_id eq $source_id;

  if (ASSERT_DATA) {
    _trap $source_session unless exists $post_count{$source_id};
  }

  $self->_data_ses_refcount_dec($source_id) unless --$post_count{$source_id};
}

### Fetch the number of pending events sent to a session.

sub _data_ev_get_count_to {
  my ($self, $sid) = @_;
  return $event_count{$sid} || 0;
}

### Fetch the number of pending events sent from a session.

sub _data_ev_get_count_from {
  my ($self, $sid) = @_;
  return $post_count{$sid} || 0;
}

### Dispatch events that are due for "now" or earlier.

sub _data_ev_dispatch_due {
  my $self = shift;

  if (TRACE_EVENTS) {
    foreach ($kr_queue->peek_items(sub { 1 })) {
      my @event = map { defined() ? $_ : "(undef)" } @{$_->[ITEM_PAYLOAD]};
      _warn(
        "<ev> time($_->[ITEM_PRIORITY]) id($_->[ITEM_ID]) ",
        "event(@event)\n"
      );
    }
  }

  my $now = monotime();
  my $next_time;
  while (
    defined($next_time = $kr_queue->get_next_priority()) and
    $next_time <= $now
  ) {
    my ($priority, $id, $event) = $kr_queue->dequeue_next();

    if (TRACE_EVENTS) {
      _warn("<ev> dispatching event $id ($event->[EV_NAME])");
    }

    # TODO - Why can't we reverse these two lines?
    # TODO - Reversing them could avoid entering and removing GC marks.
    $self->_data_ev_refcount_dec($event->[EV_SOURCE], $event->[EV_SESSION]);

    if ($event->[EV_TYPE] & ET_SIGNAL) {
      $self->_dispatch_signal_event(@{$event}[EV_SESSION..EV_FROMSTATE], $priority, $id);
    }
    else {
      $self->_dispatch_event(@{$event}[EV_SESSION..EV_FROMSTATE], $priority, $id);
    }

    # Stop the system if an unhandled exception occurred.
    # This wipes out all sessions and associated resources.
    next unless $POE::Kernel::kr_exception;
    POE::Kernel->stop();
  }

  # Sweep for dead sessions.  The sweep may alter the next queue time.

  $self->_data_ses_gc_sweep();
  $next_time = $kr_queue->get_next_priority();

  # Tell the event loop to wait for the next event, if there is one.
  # Otherwise we're going to wait indefinitely for some other event.

  if (defined $next_time) {
    $self->loop_reset_time_watcher($next_time);
  }
  else {
    $self->loop_pause_time_watcher();
  }
}

1;

__END__

=head1 NAME

POE::Resource::Events - internal event manager for POE::Kernel

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE::Resource::Events is a mix-in class for POE::Kernel.  It hides the
complexity of managing POE's events from even POE itself.  It is used
internally by POE::Kernel, so it has no public interface.

=head1 SEE ALSO

See L<POE::Kernel/Asynchronous Messages (FIFO Events)> for one public
events API.

See L<POE::Kernel/Resources> for public information about POE
resources.

See L<POE::Resource> for general discussion about resources and the
classes that manage them.

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
