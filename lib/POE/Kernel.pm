# $Id$

package POE::Kernel;

use strict;
use POSIX qw(errno_h fcntl_h sys_wait_h);
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
sub DEB_STRICT   () { 0 }
sub DEB_INSERT   () { 0 }
                                        # handles & vectors structures
sub VEC_RD      () { 0 }
sub VEC_WR      () { 1 }
sub VEC_EX      () { 2 }
                                        # sessions structure
sub SS_SESSION   () { 0 }
sub SS_REFCOUNT  () { 1 }
sub SS_EVCOUNT   () { 2 }
sub SS_PARENT    () { 3 }
sub SS_CHILDREN  () { 4 }
sub SS_HANDLES   () { 5 }
sub SS_SIGNALS   () { 6 }
sub SS_ALIASES   () { 7 }
sub SS_PROCESSES () { 8 }
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
sub KR_PROCESSES      () { 7 }
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
sub ST_SESSION () { 0 }
sub ST_SOURCE  () { 1 }
sub ST_NAME    () { 2 }
sub ST_ARGS    () { 3 }
sub ST_TIME    () { 4 }
sub ST_DEB_SEQ () { 5 }
                                        # event names
sub EN_START  () { '_start'           }
sub EN_STOP   () { '_stop'            }
sub EN_SIGNAL () { '_signal'          }
sub EN_GC     () { '_garbage_collect' }
sub EN_PARENT () { '_parent'          }
sub EN_CHILD  () { '_child'           }
sub EN_SCPOLL () { '_sigchld_poll'    }

#------------------------------------------------------------------------------
#
# states: [ [ $session, $source_session, $state, \@etc, $time ],
#           ...
#         ];
#
# processes: { $pid => $parent_session }
#
# handles: { $handle => [ $handle, $refcount, [$ref_r, $ref_w, $ref_x ],
#                         [ { $session => [ $handle, $session, $state ], .. },
#                           { $session => [ $handle, $session, $state ], .. },
#                           { $session => [ $handle, $session, $state ], .. }
#                         ]
#                       ]
#          };
#
# vectors: [ $read_vector, $write_vector, $expedite_vector ];
#
# signals: { $signal => { $session => $state, ... } };
#
# sessions: { $session => [ $session,     # blessed version of the key
#                           $refcount,    # number of things keeping this alive
#                           $evcnt,       # event count
#                           $parent,      # parent session
#                           { $child => $child, ... },
#                           { $handle => [ $hdl, $rcnt, [ $r,$w,$e ] ], ... },
#                           { $signal => $state, ... },
#                           { $name => 1, ... },
#                           { $pid => 1, ... },   # child processes
#                         ]
#           };
#
# names: { $name => $session };
#
#------------------------------------------------------------------------------

#==============================================================================
# SIGNALS
#==============================================================================

                                        # will stop sessions unless handled
my %_terminal_signals =
  ( QUIT => 1, INT => 1, KILL => 1, TERM => 1, HUP => 1, IDLE => 1 );
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
    $self->[KR_SESSIONS ] = { };
    $self->[KR_VECTORS  ] = [ '', '', '' ];
    $self->[KR_HANDLES  ] = { };
    $self->[KR_STATES   ] = [ ];
    $self->[KR_SIGNALS  ] = { };
    $self->[KR_ALIASES  ] = { };
    $self->[KR_PROCESSES] = { };
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
        # Leave SIGCHLD alone if running under apache.
        unless (exists $INC{'Apache.pm'}) {
          $SIG{$signal} = \&_signal_handler_child;
        }
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
                                        # send SIGIDLE if queue empty
    unless (@{$self->[KR_STATES]} || keys(%{$self->[KR_HANDLES]})) {
      $self->_enqueue_state($self, $self, EN_SIGNAL, time(), [ 'IDLE' ]);
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

  if ($state eq EN_SCPOLL) {

    while (my $child_pid = waitpid(-1, WNOHANG)) {
      if (exists $self->[KR_PROCESSES]->{$child_pid}) {

        my $parent_session = delete $self->[KR_PROCESSES]->{$child_pid};

        $parent_session = $self
          unless exists $self->[KR_SESSIONS]->{$parent_session};

        $poe_kernel->_enqueue_state
          ( $parent_session, $poe_kernel, EN_SIGNAL,
            time(), [ 'CHLD', $child_pid, $? ]
          );
      }
      else {
        last;
      }
    }

    if (keys %{$self->[KR_PROCESSES]}) {
      $self->_enqueue_state($self, $self, EN_SCPOLL, time() + 1);
    }

  }

  elsif ($state eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (@{$self->[KR_STATES]} || keys(%{$self->[KR_HANDLES]})) {
        $self->_enqueue_state($self, $self, EN_SIGNAL, time(), [ 'ZOMBIE' ]);
      }
    }
  }

  return 1;
}

#==============================================================================
# SESSIONS
#==============================================================================

sub session_create {
  my $self = shift;
  carp "POE::Kernel::session_create() is depreciated";
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

sub debug_insert {
  my ($states, $index, $time) = @_;

  if ($index==0) {
    warn( "<<<<< inserting time($time) at $index, before ",
          $states->[$index]->[ST_TIME],
          " >>>>>\n"
        );
  }
  elsif ($index == @$states) {
    warn( "<<<<< inserting time($time) at $index, after ",
          $states->[$index-1]->[ST_TIME],
          " >>>>>\n"
        );
  }
  else {
    warn( "<<<<< inserting time($time) at $index, between low(",
          $states->[$index-1]->[ST_TIME],
          ") and high(", 
          $states->[$index]->[ST_TIME],
          ") >>>>>\n"
        );
  }
}

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
                                        # small queue; linear search
      if (@$kr_states < 8) {
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
                                        # larger queue; binary search
      else {
        my $upper = @$kr_states - 1;
        my $lower = 0;
        while ('true') {
          my $midpoint = ($upper + $lower) >> 1;

          DEB_INSERT &&
            warn "<<<<< lo($lower)  mid($midpoint)  hi($upper) >>>>>\n";

          if ($upper < $lower) {
            DEB_INSERT && &debug_insert($kr_states, $lower, $time);
            splice(@$kr_states, $lower, 0, $state_to_queue);
            last;
          }
                                        # too high
          if ($time < $kr_states->[$midpoint]->[ST_TIME]) {
            $upper = $midpoint - 1;
            next;
          }
                                        # too low
          if ($time > $kr_states->[$midpoint]->[ST_TIME]) {
            $lower = $midpoint + 1;
            next;
          }
                                        # just right
          if ($time == $kr_states->[$midpoint]->[ST_TIME]) {
            while ( ($midpoint < @$kr_states) &&
                    ($time == $kr_states->[$midpoint]->[ST_TIME])
            ) {
              $midpoint++;
            }
            DEB_INSERT && &debug_insert($kr_states, $midpoint, $time);
            splice(@$kr_states, $midpoint, 0, $state_to_queue);
            last;
          }
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
    croak "can't enqueue state($state) for nonexistent session($session)\a\n";
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
    return 1;
  }
  if (DEB_STRICT) {
    warn "Cannot resolve alias $destination for session\n";
    confess;
  }
  return undef;
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
    my $retval = $self->_dispatch_state( $destination,
                                         $self->[KR_ACTIVE_SESSION],
                                         $state_name, \@etc
                                       );
    $! = 0;
    return $retval;
  }
  if (DEB_STRICT) {
    warn "Cannot resolve alias $destination for session\n";
    confess;
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
                                        # resolve against sessions
  if (exists $self->[KR_SESSIONS]->{$name}) {
    return $self->[KR_SESSIONS]->{$name}->[SS_SESSION];
  }
                                        # resolve against aliases
  if (exists $self->[KR_ALIASES]->{$name}) {
    return $self->[KR_ALIASES]->{$name};
  }
                                        # resolve against current namespace
  if ($self->[KR_ACTIVE_SESSION] ne $self) {
    if ($name eq $self->[KR_ACTIVE_SESSION]->[&POE::Session::SE_NAMESPACE]) {
      carp "Using HEAP instead of SESSION is depreciated";
      return $self->[KR_ACTIVE_SESSION];
    }
  }
                                        # it doesn't resolve to anything?
  $! = ESRCH;
  return undef;
}

#==============================================================================
# Safe fork and SIGCHLD.
#==============================================================================

sub fork {
  my ($self) = @_;

  # Disable the real signal handler.  How to warn?
  $SIG{CHLD} = 'IGNORE' if (exists $SIG{CHLD});
  $SIG{CLD}  = 'IGNORE' if (exists $SIG{CLD});

  my $new_pid = fork();

  # Error.
  unless (defined $new_pid) {
    return( undef, $!+0, $! ) if wantarray;
    return undef;
  }

  # Parent.
  if ($new_pid) {
    $self->[KR_PROCESSES]->{$new_pid} = $self->[KR_ACTIVE_SESSION];
    $self->[KR_SESSIONS]->{ $self->[KR_ACTIVE_SESSION]
                          }->[SS_PROCESSES]->{$new_pid} = 1;

    # Went from 0 to 1 child processes; start a poll loop.  This uses
    # a very raw, basic form of POE::Kernel::delay.
    if (keys(%{$self->[KR_PROCESSES]}) == 1) {
      $self->_enqueue_state($self, $self, EN_SCPOLL, time() + 1);
    }

    return( $new_pid, 0, 0 ) if wantarray;
    return $new_pid;
  }

  # Child.
  else {

    # Build a list of unique sessions with children.
    my %sessions;
    foreach (keys %{$self->[KR_PROCESSES]}) {
      $sessions{$_}++;
    }

    # Clean out the children for these sessions.
    foreach my $session (keys %sessions) {
      $self->[KR_SESSIONS]->{$session}->[SS_PROCESSES] = { };
    }

    # Clean out POE's child process table.
    $self->[KR_PROCESSES] = { };

    return( 0, 0, 0 ) if wantarray;
    return 0;
  }
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

__END__

=head1 NAME

POE::Kernel - POE Event Queue and Resource Manager

=head1 SYNOPSIS

  #!/usr/bin/perl -w
  use strict;
  use POE;                 # Includes POE::Kernel and POE::Session
  new POE::Session( ... ); # Bootstrap sessions are here.
  $poe_kernel->run();      # Run the kernel.
  exit;                    # Exit when the kernel's done.

  # Session management methods:
  $kernel->session_create( ... );

  # Event management methods:
  $kernel->post( $session, $state, @args );
  $kernel->yield( $state, @args );
  $kernel->call( $session, $state, @args );

  # Alarms and timers:
  $kernel->alarm( $state, $time, @args );
  $kernel->delay( $state, $seconds, @args );

  # Aliases:
  $status = $kernel->alias_set( $alias );
  $status = $kernel->alias_remove( $alias );
  $session_reference = $kernel->alias_resolve( $alias );

  # Selects:
  $kernel->select( $file_handle,
                   $read_state_name,     # or undef to remove it
                   $write_state_name,    # or undef to remove it
                   $expedite_state_same, # or undef to remove it
                 );
  $kernel->select_read( $file_handle, $read_state_name );
  $kernel->select_write( $file_handle, $write_state_name );
  $kernel->select_expedite( $file_handle, $expedite_state_name );

  # Signals:
  $kernel->sig( $signal_name, $state_name ); # Registers a handler.
  $kernel->signal( $session, $signal_name ); # Posts a signal.

  # Processes.
  $kernel->fork();   # "Safe" fork that polls for SIGCHLD.

  # States:
  $kernel->state( $state_name, $code_reference );    # Inline state
  $kernel->state( $method_name, $object_reference ); # Object state
  $kernel->state( $function_name, $package_name );   # Package state

=head1 DESCRIPTION

POE::Kernel contains POE's event loop, select logic and resource
management methods.  There can only be one POE::Kernel per process,
and it's created automatically the first time POE::Kernel is used.
This simplifies signal delivery in the present and threads support in
the future.

=head1 EXPORTED SYMBOLS

POE::Kernel exports $poe_kernel, a reference to the program's single
kernel instance.  This mainly is used in the main package, so that
$poe_kernel->run() may be called cleanly.

Sessions' states should endeavor to use $_[KERNEL], since $poe_kernel
may not be available, or it may be different than the kernel actually
invoking the object.

=head1 PUBLIC KERNEL METHODS

POE::Kernel contains methods to manage the kernel itself, sessions,
and resources such as files, signals and alarms.

Many of the public Kernel methods generate events.  Please see the
"PREDEFINED EVENTS AND PARAMETERS" section in POE::Session's
documentation.

=head2 Kernel Management Methods

=over 4

=item *

POE::Kernel::run()

POE::Kernel::run() starts the kernel's event loop.  It will not return
until all its sessions have stopped.  There are two corollaries to
this rule: It will return immediately if there are no sessions; and if
sessions never exit, neither will run().

=back

=head2 Session Management Methods

=over 4

=item *

POE::Kernel::session_create(...)

POE::Kernel::session_create(...) creates a new session in the kernel.
It is an alias for POE::Session::new(...), and it accepts the same
parameters.  Please see POE::Session::new(...) for more information.

As of version 0.07, POE::Session is a proper object with public
methods and everything.  Therefore session_create is depreciated
starting with version 0.07.

=back

=head2 Event Management Methods

Events tell sessions which state to invoke next.  States are defined
when sessions are created.  States may also be added, removed or
changed at runtime by POE::Kernel::state(), which acts on the current
session.

There are a few ways to send events to sessions.  Events can be
posted, in which case the kernel queues them and dispatches them in
FIFO order.  States can also be called immediately, bypassing the
queue.  Immediate calls can be useful for "critical sections"; for
example, POE's I/O abstractions use call() to minimize event latency.

To learn more about events and the information they convey, please see
"PREDEFINED EVENTS AND PARAMETERS" in the POE::Session documentation.

=over 4

=item *

POE::Kernel::post( $destination, $state, @args )

POE::Kernel::post places an event in the kernel's queue.  The kernel
dispatches queued events in FIFO order.  When posted events are
dispatched, their corresponding states are invoked in a scalar
context, and their return values are discarded.  Signal handlers work
differently, but they're not invoked as a result of post().

If a state's return value is important, there are at least two ways to
get it.  First, have the $destination post a return vent to its
$_[SENDER]; second, use POE::Kernel::call() instead.

POE::Kernel::post returns undef on failure, or an unspecified defined
value on success.  $! is set to the reason why the post failed.

=item *

POE::Kernel::yield( $state, @args )

POE::Kernel::yield is an alias for posting an event to the current
session.  It does not immediately swap call stacks like yield() in
real thread libraries might.  If there's a way to do this in perl, I'd
sure like to know.

=item *

POE::Kernel::call( $session, $state, $args )

POE::Kernel::call immediately dispatches an event to a session.
States invoked this way are evaluated in a scalar context, and call()
returns their return values.

call() can exercise bugs in perl and/or the C library (we're not
really sure which just yet).  This only seems to occur when one state
(state1) is destroyed from another state (state0) as a result of
state0 being called from state1.

Until that bug is pinned down and fixed, if your program dumps core
with a SIGSEGV, try changing your call()s to post()s.

call() returns undef on failure.  It may also return undef on success,
if the called state returns success.  What a mess.  call() also sets
$! to 0 on success, regardless of what it's set to in the called
state.

=back

=head2 Alarm Management Methods

Alarms are just events that are scheduled to be dispatched at some
later time.  POE's queue is a priority queue keyed on time, so these
events go to the appropriate place in the queue.  Posted events are
really enqueued for "now" (defined as whatever time() returns).

If Time::HiRes is available, POE will use it to achieve better
resolution on enqueued events.

=over 4

=item *

POE::Kernel::alarm( $state, $time, @args )

The alarm() method enqueues an event with a future dispatch time,
specified in seconds since whatever epoch time() uses (usually the
UNIX epoch).  If $time is in the past, it will be clipped to time(),
making the alarm() call synonymous to post() but with some extra
overhead.

Alarms are keyed by state name.  That is, there can be only one
pending alarm for any given state.  This is a design bug, and there
are plans to fix it.

It is possible to remove an alarm that hasn't yet been dispatched:

  $kernel->alarm( $state ); # Removes the alarm for $state

Subsequent alarms set for the same name will overwrite previous ones.
This is useful for timeout timers that must be continually refreshed.

The alarm() method can be misused to remove events from the kernel's
queue.  This happens because alarms are merely events scheduled for a
future time.  This behavior is considered to be a bug, and there are
plans to fix it.

=item *

POE::Kernel::delay( $state, $seconds, @args );

The delay() method is an alias for:

  $kernel->alarm( $state, time() + $seconds, @args );

However, because time() is called within the POE::Kernel package, it
uses Time::HiRes if it's available.  This saves programs from having
to figure out if Time::HiRes is available themselves.

All the details for POE::Kernel::alarm() apply to delay() as well.
For example, delays may be removed by omitting the $seconds and @args
parameters:

  $kernel->delay( $state ); # Removes the delay for $state

And delay() can be misused to remove events from the kernel's queue.
Please see POE::Kernel::alarm() for more information.

=back

=head2 Alias Management Methods

Aliases allow sessions to be referenced by name instead of by session
reference.  They also allow sessions to remain active without having
selects or events.  This provides support for "daemon" sessions that
act as resources but don't necessarily have resources themselves.

Aliases must be unique.  Sessions may have more than one alias.

=over 4

=item *

POE::Kernel::alias_set( $alias )

The alias_set() method sets an alias for the current session.

It returns 1 on success.  On failure, it returns 0 and sets $! to one
of:

  EEXIST - The alias already exists for another session.

=item *

POE::Kernel::alias_remove( $alias )

The alias_remove() method removes an alias for the current session.

It returns 1 on success.  On failure, it returns 0 and sets $! to one
of:

  ESRCH - The alias does not exist.
  EPERM - The alias belongs to another session.

=item *

POE::Kernel::alias_resolve( $alias )

The alias_resolve() method returns a session reference corresponding
to the given alias.  POE::Kernel does this internally, so it's usually
not necessary.

It returns a session reference on success.  On failure, it returns
undef and sets $! to one of:

  ESRCH - The alias does not exist.

=back

=head2 Select Management Methods

Selects are file handle monitors.  They generate events to indicate
when activity occurs on the file handles they watch.  POE keeps track
of how many selects are watching a file handle, and it will close the
file when nobody is looking at it.

There are three types of select.  Each corresponds to one of the bit
vectors in Perl's four-argument select() function.  "Read" selects
generate events when files become ready for reading.  "Write" selects
generate events when files are available to be written to.  "Expedite"
selects generate events when files have out-of-band information to be
read.

=over 4

=item *

POE::Kernel::select( $filehandle, $rd_state, $wr_state, $ex_state )

The select() method manipulates all three selects for a file handle at
the same time.  Selects are added for each defined state, and selects
are removed for undefined states.

=item *

POE::Kernel::select_read( $filehandle, $read_state )

The select_read() method adds or removes a file handle's read select.
It leaves the other two unchanged.

=item *

POE::Kernel::select_write( $filehandle, $write_state )

The select_write() method adds or removes a file handle's write
select.  It leaves the other two unchanged.

=item *

POE::Kernel::select_expedite( $filehandle, $expedite_state )

The select_expedite() method adds or removes a file handle's expedite
select.  It leaves the other two unchanged.

=back

=head2 Signal Management Methods

The POE::Session documentation has more information about B<_signal>
events.

POE currently does not make Perl's signals safe.  Using signals is
okay in short-lived programs, but long-uptime servers may eventually
dump core if they receive a lot of signals.  POE provides a "safe"
fork() function that periodically reaps children without using
signals; it emulates the system's SIGCHLD signal for each process in
reaps.

Mileage varies considerably.

The kernel generates B<_signal> events when it receives signals from
the operating system.  Sessions may also send signals between
themselves without involving the OS.

The kernel determines whether or not signals have been handled by
looking at B<_signal> states' return values.  If the state returns
logical true, then it means the signal was handled.  If it returns
false, then the kernel assumes the signal wasn't handled.

POE will stop sessions that don't handle some signals.  These
"terminal" signals are QUIT, INT, KILL, TERM, HUP, and the fictitious
IDLE signal.

POE broadcasts SIGIDLE to all sessions when the kernel runs out of
events to dispatch, and when there are no alarms or selects to
generate new events.

Finally, there is one fictitious signal that always stops a session:
ZOMBIE.  If the kernel remains idle after SIGIDLE is broadcast, then
SIGZOMBIE is broadcast to force reaping of zombie sessions.  This
tells these sessions (usually aliased "daemon" sessions) that nothing
is left to do, and they're as good as dead anyway.

It's normal for aliased sessions to receive IDLE and ZOMBIE when all
the sessions that may use them have gone away.

=over 4

=item *

POE::Kernel::sig( $signal_name, $state_name )

The sig() method registers a state to handle a particular signal.
Only one state in any given session may be registered for a particular
signal.  Registering a second state for the same signal will replace
the previous state with the new one.

Signals that don't have states will be dispatched to the _signal state
instead.

=item *

POE::Kernel::signal( $session, $signal_name )

The signal() method posts a signal event to a session.  It uses the
kernel's event queue, bypassing the operating system, so the signal's
name is not limited to what the OS allows.  For example, the kernel
does something similar to post a fictitious ZOMBIE signal.

  $kernel->signal($session, 'BOGUS'); # Not as bogus as it sounds.

=back

=head2 Process Management Methods

POE's signal handling is Perl's signal handling, which means that POE
won't safely handle signals as long as Perl has a problem with them.

However, POE works around this in at least SIGCHLD's case by providing
a "safe" fork() function.  &POE::Kernel::fork() blocks
$SIG{'CHLD','CLD'} and starts an event loop to poll for expired child
processes.  It emulates the system's SIGCHLD behavior by sending a
"soft" CHLD signal to the appropriate session.

Because POE knows which session called its version of fork(), it can
signal just that session that its forked child process has completed.

B<Note:> The first &POE::Kernel::fork call disables POE's usual
SIGCHLD handler, so that the poll loop can reap children safely.
Mixing plain fork and &POE::Kernel::fork isn't recommended.

=over 4

=item *

POE::Kernel::fork( )

The fork() method tries to fork a process in the usual Unix way.  In
addition, it blocks SIGCHLD and/or SIGCLD and starts an event loop to
poll for completed child processes.

POE's fork() will return different things in scalar and list contexts.
In scalar context, it returns the child PID, 0, or undef, just as
Perl's fork() does.  In a list context, it returns three items: the
child PID (or 0 or undef), the numeric version of $!, and the string
version of $!.

=back

=head2 State Management Methods

The kernel's state management method lets sessions add, change and
remove states at runtime.  Wheels use this to add and remove select
states from sessions when they're created and destroyed.

=over 4

=item *

POE::Kernel::state( $state_name, $code_reference )
POE::Kernel::state( $method_name, $object_reference )
POE::Kernel::state( $function_name, $package_name )

The state() method has three different uses, each for adding, updating
or removing a different kind of state.  It manipulates states in the
current session.

The state() method returns 1 on success.  On failure, it returns 0 and
sets $! to one of:

  ESRCH - Somehow, the current session does not exist.

This function can only register or remove one state at a time.

=over 2

=item *

Inline States

Inline states are manipulated with:

  $kernel->state($state_name, $code_reference);

If $code_reference is undef, then $state_name will be removed.  Any
pending events destined for $state_name will be redirected to
_default.

=item *

Object States

Object states are manipulated with:

  $kernel->state($method_name, $object_reference);

If $object_reference is undef, then the $method_name state will be
removed.  Any pending events destined for $method_name will be
redirected to _default.

=item *

Package States

Package states are manipulated with:

  $kernel->state($function_name, $package_name);

If $package_name is undef, then the $function_name state will be
removed.  Any pending events destined for $function_name will be
redirected to _default.

=back

=back

=head1 SEE ALSO

POE; POE::Session

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
