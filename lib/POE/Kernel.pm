# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

###############################################################################

package POE::Kernel;

use strict;
use POSIX qw(errno_h fcntl_h);
use Carp;
use vars qw($poe_kernel);

use Exporter;
@POE::Kernel::ISA = qw(Exporter);
@POE::Kernel::EXPORT = qw($poe_kernel);
                                        # allow subsecond alarms, if available
BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';
  eval {
    require Time::HiRes;
    import Time::HiRes qw(time);
  };
}

#------------------------------------------------------------------------------
# Redirect STDERR to STDOUT, and kill all the buffering.  Used
# internally for testing; it should be commented out.

# BEGIN {
#   open(STDERR, '>&STDOUT') or die $!;
#   select(STDERR); $| = 1;
#   select(STDOUT); $| = 1;
# }

#------------------------------------------------------------------------------
# Redefine __WARN__ and __DIE__ to be in different colors, so they
# stand out.  Do a caller() stack trace when something dies.  Used
# internally for testing; it should be commented out.

# BEGIN {
#   package DB;
#   if ($^O eq 'os2') {
#     $SIG{'__WARN__'} =
#       sub { my $msg = join(' ', @_);
#             $msg =~ s/[\x0d\x0a]+//g;
#             warn "\e[1;5;33;40m$msg\e[0m\n";
#           };
#     $SIG{'__DIE__'} =
#       sub { my $msg = join(' ', @_);
#             $msg =~ s/[\x0d\x0a]+//g;
#             print STDERR "\e[1;31;47m$msg\e[0m\n";
#             my $frame = 0;
#             print STDERR "\e[1;35m----- CALL TRACE -----\e[0m\n";
#             while (my ($p, $f, $l, $s, $h, $w) = caller($frame)) {
#               print STDERR "\e[1;35m";
#               if ($frame) {
#                 print STDERR "called by: ";
#               }
#               else {
#                 print STDERR "died at  : ";
#               }
#               print STDERR "$f:$l - $s\e[0m\n";
#               if ($frame && $h) {
#                 foreach (@DB::args) {
#                   print "\e[1;31m\tARG: $_\e[0m\n";
#                 }
#               }
#               $frame++;
#             }
#             print STDERR "\e[1;31m---------------------\e[0m\n";
#             die "\n";
#           };
#   }
# }

#------------------------------------------------------------------------------
# globals

$poe_kernel = undef;                    # only one active kernel; sorry

#------------------------------------------------------------------------------
                                        # debugging flags for subsystems
sub DEB_RELATION () { 0 }
sub DEB_MAIN     () { 0 }
sub DEB_GC       () { 0 }
sub DEB_EVENTS   () { 0 }
sub DEB_SELECT   () { 0 }
sub DEB_REFCOUNT () { 0 }
sub DEB_QUEUE    () { 0 }
                                        # handles & vectors structures
sub VEC_RD      () { 0 }
sub VEC_WR      () { 1 }
sub VEC_EX      () { 2 }
                                        # sessions structure
sub SS_SESSION  () { 0 }
sub SS_REFCOUNT () { 1 }
sub SS_EVCOUNT  () { 2 }
sub SS_PARENT   () { 3 }
sub SS_CHILDREN () { 4 }
sub SS_HANDLES  () { 5 }
sub SS_SIGNALS  () { 6 }
sub SS_ALIASES  () { 7 }
                                        # session handle structure
sub SH_HANDLE   () { 0 }
sub SH_REFCOUNT () { 1 }
sub SH_VECCOUNT () { 2 }
                                        # the Kernel object itself
sub KR_SESSIONS       () { 0 }
sub KR_VECTORS        () { 1 }
sub KR_HANDLES        () { 2 }
sub KR_STATES         () { 3 }
sub KR_SIGNALS        () { 4 }
sub KR_ALIASES        () { 5 }
sub KR_ACTIVE_SESSION () { 6 }
                                        # handle structure
sub HND_HANDLE   () { 0 }
sub HND_REFCOUNT () { 1 }
sub HND_VECCOUNT () { 2 }
sub HND_SESSIONS () { 3 }
                                        # handle session structure
sub HSS_HANDLE  () { 0 }
sub HSS_SESSION () { 1 }
sub HSS_STATE   () { 2 }
                                        # states / events
sub ST_SESSION  () { 0 }
sub ST_SOURCE   () { 1 }
sub ST_NAME     () { 2 }
sub ST_ARGS     () { 3 }
sub ST_TIME     () { 4 }
sub ST_DEB_SEQ  () { 5 }
                                        # event names
sub EN_START  () { '_start'           }
sub EN_STOP   () { '_stop'            }
sub EN_SIGNAL () { '_signal'          }
sub EN_GC     () { '_garbage_collect' }
sub EN_PARENT () { '_parent'          }
sub EN_CHILD  () { '_child'           }

=doc #-------------------------------------------------------------------------

states: [ [ $session, $source_session, $state, \@etc, $time ],
          ...
        ];

handles: { $handle => [ $handle, $refcount, [$ref_r, $ref_w, $ref_x ],
                        [ { $session => [ $handle, $session, $state ], .. },
                          { $session => [ $handle, $session, $state ], .. },
                          { $session => [ $handle, $session, $state ], .. }
                        ]
                      ]
         };

vectors: [ $read_vector, $write_vector, $expedite_vector ];

signals: { $signal => { $session => $state, ... } };

sessions: { $session => [ $session,     # blessed version of the key
                          $refcount,    # number of things keeping this alive
                          $evcnt,       # event count
                          $parent,      # parent session
                          { $child => $child, ... },
                          { $handle => [ $hdl, $rcnt, [ $r, $w, $e ] ], ... },
                          { $signal => $state, ... },
                          { $name => 1, ... },
                        ]
          };

names: { $name => $session };

=cut #-------------------------------------------------------------------------

#==============================================================================
# SIGNALS
#==============================================================================

                                        # will stop sessions unless handled
my %_terminal_signals = ( QUIT => 1, INT => 1, KILL => 1, TERM => 1, HUP => 1);
                                        # static signal handlers
sub _signal_handler_generic {
  if (defined(my $signal = $_[0])) {
    $poe_kernel->_enqueue_state
      ( $poe_kernel, $poe_kernel, EN_SIGNAL, time(), [ $signal ] );
    $SIG{$_[0]} = \&_signal_handler_generic;
  }
  else {
    warn "POE::Kernel::_signal_handler_generic detected an undefined signal";
  }
}

sub _signal_handler_pipe {
  if (defined(my $signal = $_[0])) {
    $poe_kernel->_enqueue_state
      ( $poe_kernel->[KR_ACTIVE_SESSION], $poe_kernel,
        EN_SIGNAL, time(), [ $signal ]
      );
    $SIG{$_[0]} = \&_signal_handler_pipe;
  }
  else {
    warn "POE::Kernel::_signal_handler_pipe detected an undefined signal";
  }
}

sub _signal_handler_child {
  if (defined(my $signal = $_[0])) {
    my $pid = wait();
    if ($pid >= 0) {
      $poe_kernel->_enqueue_state
        ( $poe_kernel, $poe_kernel, EN_SIGNAL, time(), [ 'CHLD', $pid, $? ] );
    }
    $SIG{$_[0]} = \&_signal_handler_child;
  }
  else {
    warn "POE::Kernel::_signal_handler_child detected an undefined signal";
  }
}

#------------------------------------------------------------------------------

sub _internal_sig {
  my ($self, $session, $signal, $state) = @_;

  if ($state) {
    $self->[KR_SESSIONS]->{$session}->[SS_SIGNALS]->{$signal} = $state;
    $self->[KR_SIGNALS]->{$signal}->{$session} = $state;
  }
  else {
    delete $self->[KR_SESSIONS]->{$session}->[SS_SIGNALS]->{$signal};
    delete $self->[KR_SIGNALS]->{$signal}->{$session};
  }
}

sub sig {
  my ($self, $signal, $state) = @_;
  $self->_internal_sig($self->[KR_ACTIVE_SESSION], $signal, $state);
}

sub signal {
  my ($self, $session, $signal) = @_;
  if (defined($session = $self->alias_resolve($session))) {
    $self->_enqueue_state($session, $self->[KR_ACTIVE_SESSION],
                          EN_SIGNAL, time(), [ $signal ]
                         );
  }
}

#==============================================================================
# KERNEL
#==============================================================================

sub new {
  my $type = shift;
                                        # prevent multiple instances
  unless (defined $poe_kernel) {
    my $self = $poe_kernel = bless [ ], $type;
                                        # the long way to ensure correctness
    $self->[KR_SESSIONS] = { };
    $self->[KR_VECTORS ] = [ '', '', '' ];
    $self->[KR_HANDLES ] = { };
    $self->[KR_STATES  ] = [ ];
    $self->[KR_SIGNALS ] = { };
    $self->[KR_ALIASES ] = { };
                                        # initialize the vectors *as* vectors
    vec($self->[KR_VECTORS]->[VEC_RD], 0, 1) = 0;
    vec($self->[KR_VECTORS]->[VEC_WR], 0, 1) = 0;
    vec($self->[KR_VECTORS]->[VEC_EX], 0, 1) = 0;
                                        # register signal handlers
    foreach my $signal (keys(%SIG)) {
                                        # skip fake, nonexistent, and
                                        # troublesome signals
      next if ($signal =~ /^(NUM\d+
                             |__[A-Z0-9]+__
                             |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE
                             |RTMIN|RTMAX|SETS
                             |SEGV
                             |
                            )$/x
              );

      # Artur has been experiencing problems where POE programs crash
      # after resizing xterm windows.  It was discovered that the
      # xterm resizing was sending several WINCH signals, which
      # eventually causes Perl to become unstable.  Ignoring SIGWINCH
      # seems to prevent the problem, but it's only a temporary
      # solution.  At some point, POE will include a set of Curses
      # widgets, and SIGWINCH will be needed...

      if ($signal eq 'WINCH') {
        $SIG{$signal} = 'IGNORE';
        next;
      }
                                        # register signal handlers by type
      if ($signal =~ /^CH?LD$/) {
        $SIG{$signal} = \&_signal_handler_child;
      }
      elsif ($signal eq 'PIPE') {
        $SIG{$signal} = \&_signal_handler_pipe;
      }
      else {
        $SIG{$signal} = \&_signal_handler_generic;
      }
      $self->[KR_SIGNALS]->{$signal} = { };
    }
                                        # the kernel is a session, sort of
    $self->[KR_ACTIVE_SESSION] = $self;
    my $kernel_session = $self->[KR_SESSIONS]->{$self} = [ ];
    $kernel_session->[SS_SESSION ] = $self;
    $kernel_session->[SS_REFCOUNT] = 0;
    $kernel_session->[SS_EVCOUNT ] = 0;
    $kernel_session->[SS_PARENT  ] = undef;
    $kernel_session->[SS_CHILDREN] = { };
    $kernel_session->[SS_HANDLES ] = { };
    $kernel_session->[SS_SIGNALS ] = { };
    $kernel_session->[SS_ALIASES ] = { };
  }
                                        # return the global instance
  $poe_kernel;
}

#------------------------------------------------------------------------------
# Send a state to a session right now.  Used by _disp_select to expedite
# select() states, and used by run() to deliver posted states from the queue.

sub _dispatch_state {
  my ($self, $session, $source_session, $state, $etc) = @_;
  my $local_state = $state;
  my $sessions = $self->[KR_SESSIONS];
                                        # add this session to kernel tables
  if ($state eq EN_START) {
    my $new_session = $sessions->{$session} = [ ];
    $new_session->[SS_SESSION ] = $session;
    $new_session->[SS_REFCOUNT] = 0;
    $new_session->[SS_EVCOUNT ] = 0;
    $new_session->[SS_PARENT  ] = $source_session;
    $new_session->[SS_CHILDREN] = { };
    $new_session->[SS_HANDLES ] = { };
    $new_session->[SS_SIGNALS ] = { };
    $new_session->[SS_ALIASES ] = { };
                                        # add to parent's children
    if (DEB_RELATION) {
      die "$session is its own parent\a" if ($session eq $source_session);
    }
    if (DEB_RELATION) {
      die "!!! $session already is a child of $source_session\a"
        if (exists $sessions->{$source_session}->[SS_CHILDREN]->{$session});
    }
    $sessions->{$source_session}->[SS_CHILDREN]->{$session} = $session;
    $sessions->{$source_session}->[SS_REFCOUNT]++;
    if (DEB_REFCOUNT) {
      warn("+++ parent ($source_session) receives child: ",
           $sessions->{$source_session}->[SS_REFCOUNT], "\n"
          );
    }
  }
                                        # delayed GC after _start
  elsif ($state eq EN_GC) {
    $self->_collect_garbage($session);
    return 0;
  }
                                        # warn of pending session removal
  elsif ($state eq EN_STOP) {
                                        # tell children they have new parents,
                                        # and tell parent it has new children
    my $parent   = $sessions->{$session}->[SS_PARENT];
    my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
    foreach my $child (@children) {
      $self->_dispatch_state($parent, $self, EN_CHILD, [ 'gain', $child ] );
      $self->_dispatch_state($child, $self, EN_PARENT,
                             [ $sessions->{$child}->[SS_PARENT],
                               $parent,
                             ]
                            );
    }
                                        # tell the parent its child is gone
    if (defined $parent) {
      $self->_dispatch_state($parent, $self, EN_CHILD, [ 'lose', $session ]);
    }
  }
                                        # signal preprocessing
  elsif ($state eq EN_SIGNAL) {
    my $signal = $etc->[0];
                                        # propagate to children
    my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
    foreach (@children) {
      $self->_dispatch_state($_, $self, $state, $etc);
    }
                                        # translate signal to local event
    if (exists $self->[KR_SIGNALS]->{$signal}->{$session}) {
      $local_state = $self->[KR_SIGNALS]->{$signal}->{$session};
    }
  }
                                        # the session may have been GC'd
  unless (exists $self->[KR_SESSIONS]->{$session}) {
    if (DEB_EVENTS) {
      warn ">>> discarding $state to $session (session was GC'd)\n";
    }
    return;
  }
  
  if (DEB_EVENTS) {
    warn ">>> dispatching $state to $session\n";
  }
                                        # dispatch this object's state
  my $hold_active_session = $self->[KR_ACTIVE_SESSION];
  $self->[KR_ACTIVE_SESSION] = $session;

  my $return = $session->_invoke_state($source_session, $local_state, $etc);

  if (defined $return) {
    if (substr(ref($return), 0, 5) eq 'POE::') {
      $return = "$return";
    }
  }
  else {
    $return = '';
  }

  $self->[KR_ACTIVE_SESSION] = $hold_active_session;

  if (DEB_EVENTS) {
    warn "<<< $session -> $state returns ($return)\n";
  }
                                        # if _start, notify parent
  if ($state eq EN_START) {
    $self->_dispatch_state($sessions->{$session}->[SS_PARENT], $self,
                           EN_CHILD, [ 'create', $session, $return ]
                          );
  }
                                        # if _stop, fix up tables
  elsif ($state eq EN_STOP) {
                                        # remove us from our parent
    my $parent = $sessions->{$session}->[SS_PARENT];
    if (defined $parent) {
      if (DEB_RELATION) {
        die "$session is its own parent\a" if ($session eq $parent);
        die "$session is not a child of $parent\a"
          unless (($session eq $parent) ||
                  exists($sessions->{$parent}->[SS_CHILDREN]->{$session})
                 );
      }
      delete $sessions->{$parent}->[SS_CHILDREN]->{$session};
      $sessions->{$parent}->[SS_REFCOUNT]--;
      if (DEB_REFCOUNT) {
        warn("--- parent $parent loses child $session: ", 
             $sessions->{$parent}->[SS_REFCOUNT], "\n"
            );
        die "\a" if ($sessions->{$parent}->[SS_REFCOUNT] < 0);
      }
    }
                                        # give our children to our parent
    my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
    foreach (@children) {
      if (DEB_RELATION) {
        die "$_ is already a child of $parent\a"
          if (exists $sessions->{$parent}->[SS_CHILDREN]->{$_});
      }
      $sessions->{$_}->[SS_PARENT] = $parent;
      if (defined $parent) {
        $sessions->{$parent}->[SS_CHILDREN]->{$_} = $_;
        $sessions->{$parent}->[SS_REFCOUNT]++;
        if (DEB_REFCOUNT) {
          warn("+++ parent $parent receives child: ",
               $sessions->{$parent}->[SS_REFCOUNT], "\n"
              );
        }
      }
      delete $sessions->{$session}->[SS_CHILDREN]->{$_};
      $sessions->{$session}->[SS_REFCOUNT]--;
      if (DEB_REFCOUNT) {
        warn("--- session $session loses child: ",
             $sessions->{$session}->[SS_REFCOUNT], "\n"
            );
        die "\a" if ($sessions->{$session}->[SS_REFCOUNT] < 0);
      }
    }
                                        # free lingering signals
    my @signals = keys %{$sessions->{$session}->[SS_SIGNALS]};
    foreach (@signals) {
      $self->_internal_sig($session, $_);
    }
                                        # free pending states
    my $states = $self->[KR_STATES];
    my $index = @$states;
    while ($index-- && $sessions->{$session}->[SS_EVCOUNT]) {
      if ($states->[$index]->[ST_SESSION] eq $session) {
        $sessions->{$session}->[SS_EVCOUNT]--;
        if (DEB_REFCOUNT) {
          die "\a" if ($sessions->{$session}->[SS_EVCOUNT] < 0);
        }
        $sessions->{$session}->[SS_REFCOUNT]--;
        if (DEB_REFCOUNT) {
          warn("--- discarding event for $session: ",
               $sessions->{$session}->[SS_REFCOUNT], "\n"
              );
          die "\a" if ($sessions->{$session}->[SS_REFCOUNT] < 0);
        }
        splice(@$states, $index, 1);
      }
    }
                                        # free lingering selects
    my @handles = values %{$sessions->{$session}->[SS_HANDLES]};
    foreach (@handles) {
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_RD);
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_WR);
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_EX);
    }
                                        # free lingering names
    my @aliases = keys %{$sessions->{$session}->[SS_ALIASES]};
    foreach (@aliases) {
      $self->_internal_alias_remove($session, $_);
    }
                                        # check for leaks
    if (DEB_GC) {
      my $errors = 0;
      if (my $leaked = $sessions->{$session}->[SS_REFCOUNT]) {
        warn "*** LEAK: refcount = $leaked ($session)\a\n";
        $errors++;
      }
      if (my $leaked = keys(%{$sessions->{$session}->[SS_CHILDREN]})) {
        warn "*** LEAK: children = $leaked ($session)\a\n";
        $errors++;
      }
      if (my $leaked = keys(%{$sessions->{$session}->[SS_HANDLES]})) {
        warn "*** LEAK: handles  = $leaked ($session)\a\n";
        $errors++;
      }
      if (my $leaked = keys(%{$sessions->{$session}->[SS_SIGNALS]})) {
        warn "*** LEAK: signals  = $leaked ($session)\a\n";
        $errors++;
      }
      if (my $leaked = keys(%{$sessions->{$session}->[SS_ALIASES]})) {
        warn "*** LEAK: aliases  = $leaked ($session)\a\n";
        $errors++;
      }
      die "\a" if ($errors);
    }
                                        # remove this session (should be empty)
    delete $sessions->{$session};
                                        # qarbage collect the parent
    if (defined $parent) {
      $self->_collect_garbage($parent);
    }
  }
                                        # check for death by signal
  elsif ($state eq EN_SIGNAL) {
    my $signal = $etc->[0];
                                        # stop whoever doesn't handle terminals
    if (($signal eq 'ZOMBIE') ||
        (!$return && exists($_terminal_signals{$signal}))
    ) {
      $self->session_free($session);
    }
                                        # otherwise garbage-collect
    else {
      $self->_collect_garbage($session);
    }
  }
                                        # return what the state handler did
  $return;
}

#------------------------------------------------------------------------------

sub run {
  my $self = shift;

  while (keys(%{$self->[KR_SESSIONS]})) {
                                        # send SIGZOMBIE sent if queue empty
    unless (@{$self->[KR_STATES]} || keys(%{$self->[KR_HANDLES]})) {
      $self->_enqueue_state($self, $self, EN_SIGNAL, time(), [ 'ZOMBIE' ]);
    }
                                        # select, if necessary
    my $now = time();
    my $timeout = ( (@{$self->[KR_STATES]})
                    ? ($self->[KR_STATES]->[0]->[ST_TIME] - $now)
                    : 3600
                  );
    $timeout = 0 if ($timeout < 0);

    if (DEB_QUEUE) {
      warn( '*** Kernel::run() iterating.  ' .
            sprintf("now(%.2f) timeout(%.2f) then(%.2f)\n",
                    $now-$^T, $timeout, ($now-$^T)+$timeout
                   )
          );
      warn( '*** Queue times: ' .
            join( ', ',
                  map { sprintf('%d=%.2f',
                                $_->[ST_DEB_SEQ], $_->[ST_TIME] - $now
                               )
                      } @{$self->[KR_STATES]}
                ) .
            "\n"
          );
    }
    
    if (DEB_SELECT) {
      warn ",----- SELECT BITS IN -----\n";
      warn "| READ    : ", unpack('b*', $self->[KR_VECTORS]->[VEC_RD]), "\n";
      warn "| WRITE   : ", unpack('b*', $self->[KR_VECTORS]->[VEC_WR]), "\n";
      warn "| EXPEDITE: ", unpack('b*', $self->[KR_VECTORS]->[VEC_EX]), "\n";
      warn "`--------------------------\n";
    }

    my $hits = select( my $rout = $self->[KR_VECTORS]->[VEC_RD],
                       my $wout = $self->[KR_VECTORS]->[VEC_WR],
                       my $eout = $self->[KR_VECTORS]->[VEC_EX],
                       $timeout
                     );

    if (DEB_SELECT) {
      if ($hits > 0) {
        warn "select hits = $hits\n";
      }
      elsif ($hits == 0) {
        warn "select timed out...\n";
      }
      else {
        warn "select error = $!\n";
        die "... and that's fatal.\a\n"
          unless (($! == EINPROGRESS) || ($! == EINTR));
      }
      warn ",----- SELECT BITS OUT -----\n";
      warn "| READ    : ", unpack('b*', $rout), "\n";
      warn "| WRITE   : ", unpack('b*', $wout), "\n";
      warn "| EXPEDITE: ", unpack('b*', $eout), "\n";
      warn "`---------------------------\n";
    }
                                        # gather pending selects
    if ($hits > 0) {
      my @selects = map { ( ( vec($rout, fileno($_->[HND_HANDLE]), 1)
                              ? values(%{$_->[HND_SESSIONS]->[VEC_RD]})
                              : ( )
                            ),
                            ( vec($wout, fileno($_->[HND_HANDLE]), 1)
                              ? values(%{$_->[HND_SESSIONS]->[VEC_WR]})
                              : ( )
                            ),
                            ( vec($eout, fileno($_->[HND_HANDLE]), 1)
                              ? values(%{$_->[HND_SESSIONS]->[VEC_EX]})
                              : ( )
                            )
                          )
                        } values(%{$self->[KR_HANDLES]});

      if (DEB_SELECT) {
        if (@selects) {
          warn "found pending selects: @selects\n";
        }
        else {
          die "found no selects, with $hits hits from select???\a\n";
        }
      }
                                        # dispatch the selects
      foreach my $select (@selects) {
        $self->_dispatch_state( $select->[HSS_SESSION], $select->[HSS_SESSION],
                                $select->[HSS_STATE], [ $select->[HSS_HANDLE] ]
                              );
        $self->_collect_garbage($select->[HSS_SESSION]);
      }
    }
                                        # dispatch queued events
    $now = time();
    while (@{$self->[KR_STATES]}) {

      if (DEB_QUEUE) {
        my $event = $self->[KR_STATES]->[0];
        warn( sprintf('now(%.2f) ', $now - $^T) .
              sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
              "seq($event->[ST_DEB_SEQ])  " .
              "name($event->[ST_NAME])\n"
            )
      }

      last unless ($self->[KR_STATES]->[0]->[ST_TIME] <= $now);

      my $event = shift @{$self->[KR_STATES]};

      $self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_EVCOUNT]--;
      if (DEB_REFCOUNT) {
        die "\a" if
          ($self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_EVCOUNT] < 0);
      }
      $self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_REFCOUNT]--;
      if (DEB_REFCOUNT) {
        warn("--- dispatching event to $event->[ST_SESSION]: ",
             $self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_REFCOUNT],
             "\n"
            );
        die "\a" if
          ($self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_REFCOUNT] < 0);
      }
      $self->_dispatch_state(@$event);
      $self->_collect_garbage($event->[ST_SESSION]);
    }
  }
                                        # buh-bye!
  if (DEB_MAIN) {
    warn "POE stopped.\n";
  }
                                        # oh, by the way...
  if (DEB_GC) {
    my $bits;
    if (my $leaked = keys %{$self->[KR_SESSIONS]}) {
      warn "*** KERNEL LEAK: sessions = $leaked\a\n";
    }
    $bits = unpack('b*', $self->[KR_VECTORS]->[VEC_RD]);
    if (index($bits, '1') >= 0) {
      warn "*** KERNEL LEAK: read bits = $bits\a\n";
    }
    $bits = unpack('b*', $self->[KR_VECTORS]->[VEC_WR]);
    if (index($bits, '1') >= 0) {
      warn "*** KERNEL LEAK: write bits = $bits\a\n";
    }
    $bits = unpack('b*', $self->[KR_VECTORS]->[VEC_EX]);
    if (index($bits, '1') >= 0) {
      warn "*** KERNEL LEAK: expedite bits = $bits\a\n";
    }
    if (my $leaked = keys %{$self->[KR_HANDLES]}) {
      warn "*** KERNEL LEAK: handles = $leaked\a\n";
    }
    if (my $leaked = @{$self->[KR_STATES]}) {
      warn "*** KERNEL LEAK: states = $leaked\a\n";
    }
    if (my $leaked = keys %{$self->[KR_ALIASES]}) {
      warn "*** KERNEL LEAK: aliases = $leaked\a\n";
    }
  }
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  # destroy all sessions - will cascade destruction to all resources
}

#------------------------------------------------------------------------------
# This is a dummy _invoke_state so the Kernel can pretend it's also a Session.

sub _invoke_state {
  my ($self, $source_session, $state, $etc) = @_;
  return 1;
}

#==============================================================================
# SESSIONS
#==============================================================================

sub session_create {
  my $self = shift;
  new POE::Session(@_);
}

sub session_alloc {
  my ($self, $session, @args) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  if (DEB_RELATION) {
    die "session $session already exists\a"
      if (exists $self->[KR_SESSIONS]->{$session});
  }

  $self->_dispatch_state($session, $kr_active_session, EN_START, \@args);
  $self->_enqueue_state($session, $kr_active_session, EN_GC, time(), []);
}

sub session_free {
  my ($self, $session) = @_;

  if (DEB_RELATION) {
    die "session $session doesn't exist\a"
      unless (exists $self->[KR_SESSIONS]->{$session});
  }

  $self->_dispatch_state($session, $self->[KR_ACTIVE_SESSION], EN_STOP, []);
  $self->_collect_garbage($session);
}

sub _collect_garbage {
  my ($self, $session) = @_;
                                        # check for death by starvation
  if (($session ne $self) && (exists $self->[KR_SESSIONS]->{$session})) {

    my $ss = $self->[KR_SESSIONS]->{$session};

    if (DEB_GC) {
      warn ",----- GC test for $session -----\n";
      warn "| ref. count    : $ss->[SS_REFCOUNT]\n";
      warn "| event count   : $ss->[SS_EVCOUNT]\n";
      warn "| child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n";
      warn "| handles in use: ", scalar(keys(%{$ss->[SS_HANDLES]})), "\n";
      warn "| aliases in use: ", scalar(keys(%{$ss->[SS_ALIASES]})), "\n";
      warn "`---------------------------------------------------\n";
      warn "<<< GARBAGE: $session\n" unless ($ss->[SS_REFCOUNT]);
    }

    if (DEB_REFCOUNT) {
      my $calc_ref = $ss->[SS_EVCOUNT] +
        scalar(keys(%{$ss->[SS_CHILDREN]})) +
        scalar(keys(%{$ss->[SS_HANDLES]})) +
        scalar(keys(%{$ss->[SS_ALIASES]}));
      die if ($calc_ref != $ss->[SS_REFCOUNT]);

      foreach (values %{$ss->[SS_HANDLES]}) {
        $calc_ref = $_->[SH_VECCOUNT]->[VEC_RD] +
          $_->[SH_VECCOUNT]->[VEC_WR] + $_->[SH_VECCOUNT]->[VEC_EX];
        die if ($calc_ref != $_->[SH_REFCOUNT]);
      }
    }

    unless ($ss->[SS_REFCOUNT]) {
      $self->session_free($session);
    }
  }
}

#==============================================================================
# EVENTS
#==============================================================================

my $queue_seqnum = 0;

sub _enqueue_state {
  my ($self, $session, $source_session, $state, $time, $etc) = @_;

  my $state_to_queue = [ $session, $source_session, $state, $etc, $time ];

  if (DEB_QUEUE) {
    $state_to_queue->[ST_DEB_SEQ]  = ++$queue_seqnum;
  }

  if (DEB_EVENTS) {
    warn "}}} enqueuing $state for $session\n";
  }

  if (exists $self->[KR_SESSIONS]->{$session}) {
    my $kr_states = $self->[KR_STATES];
    if (@$kr_states) {
      my $index = @$kr_states;
      while ($index--) {
        if ($time >= $kr_states->[$index]->[ST_TIME]) {
          splice(@$kr_states, $index+1, 0, $state_to_queue);
          last;
        }
        elsif ($index == 0) {
          unshift @$kr_states, $state_to_queue;
        }
      }
    }
    else {
      $kr_states->[0] = $state_to_queue;
    }
    $self->[KR_SESSIONS]->{$session}->[SS_EVCOUNT]++;
    $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT]++;
    if (DEB_REFCOUNT) {
      warn("+++ enqueuing state for $session: ",
           $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT], "\n"
          );
    }
  }
  else {
    warn ">>>>> ", join('; ', keys(%{$self->[KR_SESSIONS]})), " <<<<<\n";
    die "can't enqueue state for nonexistent session\a\n";
  }
}

#------------------------------------------------------------------------------
# Post a state to the queue.

sub post {
  my ($self, $destination, $state_name, @etc) = @_;
  if (defined($destination = $self->alias_resolve($destination))) {
    $self->_enqueue_state($destination, $self->[KR_ACTIVE_SESSION],
                          $state_name, time(), \@etc
                         );
  }
}

#------------------------------------------------------------------------------
# Post a state to the queue for the current session.

sub yield {
  my ($self, $state_name, @etc) = @_;

  $self->_enqueue_state($self->[KR_ACTIVE_SESSION], $self->[KR_ACTIVE_SESSION],
                        $state_name, time(), \@etc
                       );
}

#------------------------------------------------------------------------------
# Call a state directly.

sub call {
  my ($self, $destination, $state_name, @etc) = @_;
  if (defined($destination = $self->alias_resolve($destination))) {
    return $self->_dispatch_state($destination, $self->[KR_ACTIVE_SESSION],
                                  $state_name, \@etc
                                 );
  }
  return undef;
}

#==============================================================================
# DELAYED EVENTS
#==============================================================================

sub alarm {
  my ($self, $state, $time, @etc) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
                                        # remove alarm (all instances)
  my $index = scalar(@{$self->[KR_STATES]});
  while ($index--) {
    if (($self->[KR_STATES]->[$index]->[ST_SESSION] eq $kr_active_session) &&
        ($self->[KR_STATES]->[$index]->[ST_NAME] eq $state)
    ) {
      $self->[KR_SESSIONS]->{$kr_active_session}->[SS_EVCOUNT]--;
      if (DEB_REFCOUNT) {
        die if ($self->[KR_SESSIONS]->{$kr_active_session}->[SS_EVCOUNT] < 0);
      }
      $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT]--;
      if (DEB_REFCOUNT) {
        warn("--- removing alarm for $kr_active_session: ",
             $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT], "\n"
            );
        die if ($self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT] < 0);
      }
      splice(@{$self->[KR_STATES]}, $index, 1);
    }
  }
                                        # add alarm (if non-zero time)
  if ($time) {
    if ($time < (my $now = time())) {
      $time = $now;
    }
    $self->_enqueue_state($kr_active_session, $kr_active_session,
                          $state, $time, [ @etc ]
                         );
  }
}

sub delay {
  my ($self, $state, $delay, @etc) = @_;
  if (defined $delay) {
    $self->alarm($state, time() + $delay, @etc);
  }
  else {
    $self->alarm($state, 0);
  }
}

#==============================================================================
# SELECTS
#==============================================================================

sub _internal_select {
  my ($self, $session, $handle, $state, $select_index) = @_;
  my $kr_handles = $self->[KR_HANDLES];
                                        # register a select state
  if ($state) {
    unless (exists $kr_handles->{$handle}) {
      $kr_handles->{$handle} = [ $handle, 0, [ 0, 0, 0 ], [ { }, { }, { } ] ];
                                        # for DOSISH systems like OS/2
      binmode($handle);
                                        # set the handle non-blocking
                                        # do it the Win32 way
      if ($^O eq 'MSWin32') {
        my $set_it = "1";
                                        # 126 is FIONBIO
        ioctl($handle, 126 | (ord('f')<<8) | (4<<16) | 0x80000000, $set_it)
          or croak "Can't set the handle non-blocking: $!\n";
      }
                                        # do it the way everyone else does
      else {
        my $flags = fcntl($handle, F_GETFL, 0)
          or croak "fcntl fails with F_GETFL: $!\n";
        $flags = fcntl($handle, F_SETFL, $flags | O_NONBLOCK)
          or croak "fcntl fails with F_SETFL: $!\n";
      }

#      setsockopt($handle, SOL_SOCKET, &TCP_NODELAY, 1)
#        or die "Couldn't disable Nagle's algorithm: $!\a\n";

                                        # turn off buffering
      select((select($handle), $| = 1)[0]);
    }
                                        # KR_HANDLES
    my $kr_handle = $kr_handles->{$handle};
    unless (exists $kr_handle->[HND_SESSIONS]->[$select_index]->{$session}) {
      $kr_handle->[HND_VECCOUNT]->[$select_index]++;
      if ($kr_handle->[HND_VECCOUNT]->[$select_index] == 1) {
        vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 1;
      }
      $kr_handle->[HND_REFCOUNT]++;
    }
    $kr_handle->[HND_SESSIONS]->[$select_index]->{$session} =
      [ $handle, $session, $state ];
                                        # SS_HANDLES
    my $kr_session = $self->[KR_SESSIONS]->{$session};
    unless (exists $kr_session->[SS_HANDLES]->{$handle}) {
      $kr_session->[SS_HANDLES]->{$handle} = [ $handle, 0, [ 0, 0, 0 ] ];
      $kr_session->[SS_REFCOUNT]++;
      if (DEB_REFCOUNT) {
        warn("+++ added select for $session: ",
             $kr_session->[SS_REFCOUNT], "\n"
            );
      }
    }

    my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
    unless ($ss_handle->[SH_VECCOUNT]->[$select_index]) {
      $ss_handle->[SH_VECCOUNT]->[$select_index] = 1;
      $ss_handle->[SH_REFCOUNT]++;
    }
  }
                                        # remove a state, and possibly more
  else {
                                        # KR_HANDLES
    if (exists $kr_handles->{$handle}) {
      my $kr_handle = $kr_handles->{$handle};
      if (exists $kr_handle->[HND_SESSIONS]->[$select_index]->{$session}) {
        delete $kr_handle->[HND_SESSIONS]->[$select_index]->{$session};
        $kr_handle->[HND_VECCOUNT]->[$select_index]--;
        if (DEB_REFCOUNT) {
          die if ($kr_handle->[HND_VECCOUNT]->[$select_index] < 0);
        }
        unless ($kr_handle->[HND_VECCOUNT]->[$select_index]) {
          vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 0;
        }
        $kr_handle->[HND_REFCOUNT]--;
        if (DEB_REFCOUNT) {
          die if ($kr_handle->[HND_REFCOUNT] < 0);
        }
        unless ($kr_handle->[HND_REFCOUNT]) {
          delete $kr_handles->{$handle};
        }
      }
    }
                                        # SS_HANDLES
    my $kr_session = $self->[KR_SESSIONS]->{$session};
    if (exists $kr_session->[SS_HANDLES]->{$handle}) {
      my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
      if ($ss_handle->[SH_VECCOUNT]->[$select_index]) {
        $ss_handle->[SH_VECCOUNT]->[$select_index] = 0;
        $ss_handle->[SH_REFCOUNT]--;
        if (DEB_REFCOUNT) {
          die if ($ss_handle->[SH_REFCOUNT] < 0);
        }
        unless ($ss_handle->[SH_REFCOUNT]) {
          delete $kr_session->[SS_HANDLES]->{$handle};
          $kr_session->[SS_REFCOUNT]--;
          if (DEB_REFCOUNT) {
            warn("--- removed select for $session: ",
                 $kr_session->[SS_REFCOUNT], "\n"
                );
            die if ($kr_session->[SS_REFCOUNT] < 0);
          }
        }
      }
    }
  }
}

sub select {
  my ($self, $handle, $state_r, $state_w, $state_e) = @_;
  my $session = $self->[KR_ACTIVE_SESSION];
  $self->_internal_select($session, $handle, $state_r, VEC_RD);
  $self->_internal_select($session, $handle, $state_w, VEC_WR);
  $self->_internal_select($session, $handle, $state_e, VEC_EX);
}

sub select_read {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, 0);
};

sub select_write {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, 1);
};

sub select_expedite {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, 2);
};

#==============================================================================
# ALIASES
#==============================================================================

sub alias_set {
  my ($self, $name) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  if (exists $self->[KR_ALIASES]->{$name}) {
    if ($self->[KR_ALIASES]->{$name} ne $kr_active_session) {
      $! = EEXIST;
      return 0;
    }
    return 1;
  }

  $self->[KR_ALIASES]->{$name} = $kr_active_session;
  $self->[KR_SESSIONS]->{$kr_active_session}->[SS_ALIASES]->{$name} = 1;
  $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT]++;
  if (DEB_REFCOUNT) {
    warn("+++ added alias for $kr_active_session: ",
         $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT], "\n"
        );
  }
  return 1;
}

sub _internal_alias_remove {
  my ($self, $session, $name) = @_;
  delete $self->[KR_ALIASES]->{$name};
  delete $self->[KR_SESSIONS]->{$session}->[SS_ALIASES]->{$name};
  $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT]--;
  if (DEB_REFCOUNT) {
    warn("--- removed alias for $session: ",
         $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT], "\n"
        );
    die if ($self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT] < 0);
  }
}

sub alias_remove {
  my ($self, $name) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  unless (exists $self->[KR_ALIASES]->{$name}) {
    $! = ESRCH;
    return 0;
  }

  if ($self->[KR_ALIASES]->{$name} ne $kr_active_session) {
    $! = EPERM;
    return 0;
  }

  $self->_internal_alias_remove($kr_active_session, $name);
  return 1;
}

sub alias_resolve {
  my ($self, $name) = @_;
                                        # resolve against current namespace
  if ($self->[KR_ACTIVE_SESSION] ne $self) {
    if ($name eq $self->[KR_ACTIVE_SESSION]->{'namespace'}) {
      carp "Using HEAP instead of SESSION is depreciated";
      return $self->[KR_ACTIVE_SESSION];
    }
  }
                                        # resolve against itself
  if (ref($name) ne '') {
    return $name;
  }
                                        # resolve against aliases
  if (exists $self->[KR_ALIASES]->{$name}) {
    return $self->[KR_ALIASES]->{$name};
  }
                                        # resolve against sessions
  if (exists $self->[KR_SESSIONS]->{$name}) {
    return $self->[KR_SESSIONS]->{$name}->[SS_SESSION];
  }
                                        # it doesn't resolve to anything?
  $! = ESRCH;
  return undef;
}

#==============================================================================
# HANDLERS
#==============================================================================

sub state {
  my ($self, $state_name, $state_code) = @_;
  if ( (ref($self->[KR_ACTIVE_SESSION]) ne '') &&
                                        # -><- breaks subclasses... sky has fix
       (ref($self->[KR_ACTIVE_SESSION]) ne 'POE::Kernel')
  ) {
    $self->[KR_ACTIVE_SESSION]->register_state($state_name, $state_code);
    return 1;
  }
                                        # no such session
  $! = ESRCH;
  return 0;
}

###############################################################################
# Bootstrap the kernel.  This is inherited from a time when multiple
# kernels could be present in the same Perl process.

new POE::Kernel();

###############################################################################
1;
