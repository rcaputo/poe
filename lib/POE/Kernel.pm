# $Id$

package POE::Kernel;

use strict;
use POSIX qw(errno_h fcntl_h sys_wait_h uname);
use Carp;
use vars qw( $poe_kernel );

use Exporter;
@POE::Kernel::ISA = qw(Exporter);
@POE::Kernel::EXPORT = qw( $poe_kernel );

# Perform some optional setup.
BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';

  # Include Time::HiRes, which is pretty darned cool, if it's
  # available.  Life goes on without it.
  eval {
    require Time::HiRes;
    import Time::HiRes qw(time);
  };

  # Provide a dummy EINPROGRESS for systems that don't have one.  Give
  # it an improbable errno value.
  if ($^O eq 'MSWin32') {
    eval '*EINPROGRESS = sub { 3.141 };'
  }
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

# Debugging flags for subsystems.  They're done as double evals here
# so that someone may define them before using POE, and the
# pre-defined value will take precedence over the defaults here.
BEGIN {
  defined &DEB_EVENTS   or eval 'sub DEB_EVENTS   () { 0 }';
  defined &DEB_GC       or eval 'sub DEB_GC       () { 0 }';
  defined &DEB_INSERT   or eval 'sub DEB_INSERT   () { 0 }';
  defined &DEB_MAIN     or eval 'sub DEB_MAIN     () { 0 }';
  defined &DEB_PROFILE  or eval 'sub DEB_PROFILE  () { 0 }';
  defined &DEB_QUEUE    or eval 'sub DEB_QUEUE    () { 0 }';
  defined &DEB_REFCOUNT or eval 'sub DEB_REFCOUNT () { 0 }';
  defined &DEB_RELATION or eval 'sub DEB_RELATION () { 0 }';
  defined &DEB_SELECT   or eval 'sub DEB_SELECT   () { 0 }';
  defined &DEB_STRICT   or eval 'sub DEB_STRICT   () { 0 }';
}
                                        # handles & vectors structures
sub VEC_RD       () { 0 }
sub VEC_WR       () { 1 }
sub VEC_EX       () { 2 }
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
sub SS_ID        () { 9 }
                                        # session handle structure
sub SH_HANDLE    () { 0 }
sub SH_REFCOUNT  () { 1 }
sub SH_VECCOUNT  () { 2 }
                                        # the Kernel object itself
sub KR_SESSIONS       () { 0  }
sub KR_VECTORS        () { 1  }
sub KR_HANDLES        () { 2  }
sub KR_STATES         () { 3  }
sub KR_SIGNALS        () { 4  }
sub KR_ALIASES        () { 5  }
sub KR_ACTIVE_SESSION () { 6  }
sub KR_PROCESSES      () { 7  }
sub KR_ID             () { 9  }
sub KR_SESSION_IDS    () { 10 }
sub KR_ID_INDEX       () { 11 }
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
sub ST_SESSION    () { 0 }
sub ST_SOURCE     () { 1 }
sub ST_NAME       () { 2 }
sub ST_TYPE       () { 3 }
sub ST_ARGS       () { 4 }
sub ST_TIME       () { 5 } # goes towards end
sub ST_OWNER_FILE () { 6 } # goes towards end
sub ST_OWNER_LINE () { 7 } # goes towards end
sub ST_DEB_SEQ    () { 8 } # goes very last

# These are names of internal events.

sub EN_START  () { '_start'           }
sub EN_STOP   () { '_stop'            }
sub EN_SIGNAL () { '_signal'          }
sub EN_GC     () { '_garbage_collect' }
sub EN_PARENT () { '_parent'          }
sub EN_CHILD  () { '_child'           }
sub EN_SCPOLL () { '_sigchld_poll'    }

# These are event classes (types).  They often shadow actual event
# names, but they can encompass a large group of events.  For example,
# ET_ALARM describes anything posted by an alarm call.

sub ET_USER   () { 0x0000 }
sub ET_START  () { 0x0001 }
sub ET_STOP   () { 0x0002 }
sub ET_SIGNAL () { 0x0004 }
sub ET_GC     () { 0x0008 }
sub ET_PARENT () { 0x0010 }
sub ET_CHILD  () { 0x0020 }
sub ET_SCPOLL () { 0x0040 }
sub ET_ALARM  () { 0x0080 }
sub ET_SELECT () { 0x0100 }

#------------------------------------------------------------------------------
#
# states: [ [ $session, $source_session, $state, $type, \@etc, $time ],
#           ...
#         ];
#
# processes: { $pid => $parent_session, ... }
#
# kernel ID: { $kernel_id }
#
# session IDs: { $id => $session, ... }
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
#                           $session_id,  # session ID
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
      ( $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL,
        [ $signal ], time(), __FILE__, __LINE__
      );
    $SIG{$_[0]} = \&_signal_handler_generic;
  }
  else {
    warn "POE::Kernel::_signal_handler_generic detected an undefined signal";
  }
}

sub _signal_handler_pipe {
  if (defined(my $signal = $_[0])) {
    $poe_kernel->_enqueue_state
      ( $poe_kernel->[KR_ACTIVE_SESSION], $poe_kernel, EN_SIGNAL, ET_SIGNAL,
        [ $signal ], time(), __FILE__, __LINE__
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
        ( $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL,
          [ 'CHLD', $pid, $? ], time(), __FILE__, __LINE__
        );
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
  my ($file, $line) = (caller)[1,2];

  if (defined($session = $self->alias_resolve($session))) {
    $self->_enqueue_state( $session, $self->[KR_ACTIVE_SESSION],
                           EN_SIGNAL, ET_SIGNAL, [ $signal ], time(),
                           $file, $line
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

    # Kernel ID, based on Philip Gwyn's code.  I hope he still can
    # recognize it.  KR_SESSION_IDS is a hash because it will almost
    # always be sparse.
    $self->[KR_ID         ] = ( (uname)[1] . '-' .
                                unpack 'H*', pack 'N*', time, $$
                              );
    $self->[KR_SESSION_IDS] = { };
    $self->[KR_ID_INDEX]    = 1;

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
    $kernel_session->[SS_ID      ] = $self->[KR_ID];
  }
                                        # return the global instance
  $poe_kernel;
}

#------------------------------------------------------------------------------
# Send a state to a session right now.  Used by _disp_select to expedite
# select() states, and used by run() to deliver posted states from the queue.

my %profile;

sub _dispatch_state {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line, $seq
     ) = @_;

  my $local_state = $state;
  my $sessions = $self->[KR_SESSIONS];

  DEB_PROFILE and $profile{$state}++;

  # The _start state is dispatched immediately as part of allocating a
  # session.  Set up the kernel's tables for this session.

  if ($type) {
    if ($type & ET_START) {
      my $new_session = $sessions->{$session} = [ ];
      $new_session->[SS_SESSION ] = $session;
      $new_session->[SS_REFCOUNT] = 0;
      $new_session->[SS_EVCOUNT ] = 0;
      $new_session->[SS_PARENT  ] = $source_session;
      $new_session->[SS_CHILDREN] = { };
      $new_session->[SS_HANDLES ] = { };
      $new_session->[SS_SIGNALS ] = { };
      $new_session->[SS_ALIASES ] = { };
      $new_session->[SS_ID      ] = $self->[KR_ID_INDEX]++;
      $self->[KR_SESSION_IDS]->{$new_session->[SS_ID]} = $session;
                                        # add to parent's children
      DEB_RELATION and do {
        die "Session ", $session->ID, " is its own parent\a"
          if ($session eq $source_session);
        die( "!!! Session ", $session->ID,
             " already is a child of session ", $source_session->ID, "\a"
           )
          if (exists $sessions->{$source_session}->[SS_CHILDREN]->{$session});
      };
      $sessions->{$source_session}->[SS_CHILDREN]->{$session} = $session;
      $sessions->{$source_session}->[SS_REFCOUNT]++;

      DEB_REFCOUNT and do {
        warn( "+++ Parent session ", $source_session->ID,
              " receives child.  New refcount=",
              $sessions->{$source_session}->[SS_REFCOUNT], "\n"
            );
      };
    }
                                        # delayed GC after _start
    elsif ($type & ET_GC) {
      $self->_collect_garbage($session);
      return 0;
    }
                                        # warn of pending session removal
    elsif ($type & ET_STOP) {
                                        # tell children they have new parents,
                                        # and tell parent it has new children
      my $parent   = $sessions->{$session}->[SS_PARENT];
      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach my $child (@children) {
        $self->_dispatch_state( $parent, $self, EN_CHILD, ET_CHILD,
                                [ 'gain', $child ], time(), $file, $line,
                                undef
                              );
        $self->_dispatch_state( $child, $self, EN_PARENT, ET_PARENT,
                                [ $sessions->{$child}->[SS_PARENT], $parent, ],
                                time(), $file, $line, undef
                              );
      }
                                        # tell the parent its child is gone
      if (defined $parent) {
        $self->_dispatch_state( $parent, $self, EN_CHILD, ET_CHILD,
                                [ 'lose', $session ],
                                time(), $file, $line, undef
                              );
      }
    }
                                        # signal preprocessing
    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];
                                        # propagate to children
      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach (@children) {
        $self->_dispatch_state( $_, $self, $state, ET_SIGNAL, $etc,
                                time(), $file, $line, undef
                              );
      }
                                        # translate signal to local event
      if (exists $self->[KR_SIGNALS]->{$signal}->{$session}) {
        $local_state = $self->[KR_SIGNALS]->{$signal}->{$session};
      }
    }
  }
                                        # the session may have been GC'd
  unless (exists $self->[KR_SESSIONS]->{$session}) {
    DEB_EVENTS and do {
      warn( ">>> discarding $state to session ",
            $session->ID, " (session was GC'd)\n"
          );
    };
    return;
  }

  DEB_EVENTS and do {
    warn ">>> dispatching $state to session ", $session->ID, "\n";
  };
                                        # dispatch this object's state
  my $hold_active_session = $self->[KR_ACTIVE_SESSION];
  $self->[KR_ACTIVE_SESSION] = $session;

  my $return =
    $session->_invoke_state($source_session, $local_state, $etc, $file, $line);

  if (defined $return) {
    if (substr(ref($return), 0, 5) eq 'POE::') {
      $return = "$return";
    }
  }
  else {
    $return = '';
  }

  $self->[KR_ACTIVE_SESSION] = $hold_active_session;

  DEB_EVENTS and do {
    warn "<<< Session ", $session->ID, " -> $state returns ($return)\n";
  };
                                        # if _start, notify parent
  if ($type) {
    if ($type & ET_START) {
      $self->_dispatch_state( $sessions->{$session}->[SS_PARENT], $self,
                              EN_CHILD, ET_CHILD,
                              [ 'create', $session, $return ],
                              time(), $file, $line, undef
                            );
    }
                                        # if _stop, fix up tables
    elsif ($type & ET_STOP) {
                                        # remove us from our parent
      my $parent = $sessions->{$session}->[SS_PARENT];
      if (defined $parent) {
        DEB_RELATION and do {
          die "Session ", $session->ID, " is its own parent\a"
            if ($session eq $parent);
          die( "Session ", $session->ID, " is not a child of session ",
               $parent->ID, "\a"
             )
            unless (($session eq $parent) ||
                    exists($sessions->{$parent}->[SS_CHILDREN]->{$session})
                   );
        };
        delete $sessions->{$parent}->[SS_CHILDREN]->{$session};
        $sessions->{$parent}->[SS_REFCOUNT]--;
        DEB_REFCOUNT and do {
          warn( "--- parent session ", $parent->ID, " loses child session ",
                $session->ID, ". New refcount=",
                $sessions->{$parent}->[SS_REFCOUNT], "\n"
              );
          die "\a" if ($sessions->{$parent}->[SS_REFCOUNT] < 0);
        };
      }
                                        # give our children to our parent
      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach (@children) {
        DEB_RELATION and do {
          die( "Session ", $_->ID, " is already a child of session ",
               $parent->ID, "\a"
             )
            if (exists $sessions->{$parent}->[SS_CHILDREN]->{$_});
        };
        $sessions->{$_}->[SS_PARENT] = $parent;
        if (defined $parent) {
          $sessions->{$parent}->[SS_CHILDREN]->{$_} = $_;
          $sessions->{$parent}->[SS_REFCOUNT]++;
          DEB_REFCOUNT and do {
            warn( "+++ parent session ", $parent->ID,
                  " receives child. new refcount=",
                  $sessions->{$parent}->[SS_REFCOUNT], "\n"
                );
          };
        }
        delete $sessions->{$session}->[SS_CHILDREN]->{$_};
        $sessions->{$session}->[SS_REFCOUNT]--;
        DEB_REFCOUNT and do {
          warn( "--- session ", $session->ID, " loses child.  new refcount=",
                $sessions->{$session}->[SS_REFCOUNT], "\n"
              );
          die "\a" if ($sessions->{$session}->[SS_REFCOUNT] < 0);
        };
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
          DEB_REFCOUNT and do {
            die "\a" if ($sessions->{$session}->[SS_EVCOUNT] < 0);
          };
          $sessions->{$session}->[SS_REFCOUNT]--;
          DEB_REFCOUNT and do {
            warn( "--- discarding event for session ", $session->ID, ": ",
                  $sessions->{$session}->[SS_REFCOUNT], "\n"
                );
            die "\a" if ($sessions->{$session}->[SS_REFCOUNT] < 0);
          };
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
                                        # remove session ID
      delete $self->[KR_SESSION_IDS]->{$sessions->{$session}->[SS_ID]};
      $session->[SS_ID] = undef;
                                        # check for leaks
      DEB_GC and do {
        my $errors = 0;
        if (my $leaked = $sessions->{$session}->[SS_REFCOUNT]) {
          warn "*** LEAK: refcount = $leaked (session ", $session->ID, ")\a\n";
          $errors++;
        }
        if (my $leaked = keys(%{$sessions->{$session}->[SS_CHILDREN]})) {
          warn "*** LEAK: children = $leaked (session ", $session->ID, ")\a\n";
          $errors++;
        }
        if (my $leaked = keys(%{$sessions->{$session}->[SS_HANDLES]})) {
          warn "*** LEAK: handles  = $leaked (session ", $session->ID, ")\a\n";
          $errors++;
        }
        if (my $leaked = keys(%{$sessions->{$session}->[SS_SIGNALS]})) {
          warn "*** LEAK: signals  = $leaked (session ", $session->ID, ")\a\n";
          $errors++;
        }
        if (my $leaked = keys(%{$sessions->{$session}->[SS_ALIASES]})) {
          warn "*** LEAK: aliases  = $leaked (session ", $session->ID, ")\a\n";
          $errors++;
        }
        die "\a" if ($errors);
      };
                                        # remove this session (should be empty)
      delete $sessions->{$session};
                                        # qarbage collect the parent
      if (defined $parent) {
        $self->_collect_garbage($parent);
      }
    }
                                        # check for death by signal
    elsif ($type & ET_SIGNAL) {
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
      $self->_enqueue_state( $self, $self, EN_SIGNAL, ET_SIGNAL,
                             [ 'IDLE' ], time(), __FILE__, __LINE__
                           );
    }
                                        # select, if necessary
    my $now = time();
    my $timeout = ( (@{$self->[KR_STATES]})
                    ? ($self->[KR_STATES]->[0]->[ST_TIME] - $now)
                    : 3600
                  );
    $timeout = 0 if ($timeout < 0);

    DEB_QUEUE and do {
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
    };

    DEB_SELECT and do {
      warn ",----- SELECT BITS IN -----\n";
      warn "| READ    : ", unpack('b*', $self->[KR_VECTORS]->[VEC_RD]), "\n";
      warn "| WRITE   : ", unpack('b*', $self->[KR_VECTORS]->[VEC_WR]), "\n";
      warn "| EXPEDITE: ", unpack('b*', $self->[KR_VECTORS]->[VEC_EX]), "\n";
      warn "`--------------------------\n";
    };

    my $hits = select( my $rout = $self->[KR_VECTORS]->[VEC_RD],
                       my $wout = $self->[KR_VECTORS]->[VEC_WR],
                       my $eout = $self->[KR_VECTORS]->[VEC_EX],
                       $timeout
                     );

    DEB_SELECT and do {
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
    };
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

      DEB_SELECT and do {
        if (@selects) {
          warn "found pending selects: @selects\n";
        }
        else {
          die "found no selects, with $hits hits from select???\a\n";
        }
      };
                                        # dispatch the selects
      foreach my $select (@selects) {
        $self->_dispatch_state( $select->[HSS_SESSION], $select->[HSS_SESSION],
                                $select->[HSS_STATE], ET_SELECT,
                                [ $select->[HSS_HANDLE] ],
                                time(), __FILE__, __LINE__, undef
                              );
        $self->_collect_garbage($select->[HSS_SESSION]);
      }
    }
                                        # dispatch queued events
    $now = time();
    while (@{$self->[KR_STATES]}
           and ($self->[KR_STATES]->[0]->[ST_TIME] <= $now)
    ) {

      DEB_QUEUE and do {
        my $event = $self->[KR_STATES]->[0];
        warn( sprintf('now(%.2f) ', $now - $^T) .
              sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
              "seq($event->[ST_DEB_SEQ])  " .
              "name($event->[ST_NAME])\n"
            )
      };

      my $event = shift @{$self->[KR_STATES]};

      $self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_EVCOUNT]--;

      DEB_REFCOUNT and do {
        die "\a" if
          ($self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_EVCOUNT] < 0);
      };

      $self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_REFCOUNT]--;
      DEB_REFCOUNT and do {
        warn( "--- dispatching event to session ", $event->[ST_SESSION]->ID,
              ": ",
              $self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_REFCOUNT],
              "\n"
            );
        die "\a" if
          ($self->[KR_SESSIONS]->{$event->[ST_SESSION]}->[SS_REFCOUNT] < 0);
      };
      $self->_dispatch_state(@$event);
      $self->_collect_garbage($event->[ST_SESSION]);
    }
  }
                                        # buh-bye!
  DEB_MAIN and do {
    warn "POE stopped.\n";
  };
                                        # oh, by the way...
  DEB_GC and do {
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
  };

  DEB_PROFILE and do {
    my $title = ',----- State Profile ';
    $title .= '-' x (74 - length($title)) . ',';
    warn $title, "\n";
    foreach (sort keys %profile) {
      printf "| %60s %10d |\n", $_, $profile{$_};
    }
    warn '`', '-' x 73, "'\n";
  }
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  # Destroy all sessions.  This will cascade destruction to all
  # resources.  It's taken care of by Perl's own garbage collection.
  # For completeness, I suppose a copy of POE::Kernel->run's leak
  # detection should be included here.
}

#------------------------------------------------------------------------------
# This is a dummy _invoke_state so the Kernel can pretend it's also a Session.

sub _invoke_state {
  my ($self, $source_session, $state, $etc) = @_;

  if ($state eq EN_SCPOLL) {

    while (my $child_pid = waitpid(-1, WNOHANG)) {
      if (my $parent_session = delete $self->[KR_PROCESSES]->{$child_pid}) {
        $parent_session = $self
          unless exists $self->[KR_SESSIONS]->{$parent_session};
        $self->_enqueue_state( $parent_session, $self,
                               EN_SIGNAL, ET_SIGNAL,
                               [ 'CHLD', $child_pid, $? ], time(),
                               __FILE__, __LINE__
                             );
      }
      else {
        last;
      }
    }

    if (keys %{$self->[KR_PROCESSES]}) {
      $self->_enqueue_state( $self, $self, EN_SCPOLL, ET_SCPOLL,
                             [], time() + 1, __FILE__, __LINE__
                           );
    }
  }

  elsif ($state eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (@{$self->[KR_STATES]} || keys(%{$self->[KR_HANDLES]})) {
        $self->_enqueue_state( $self, $self, EN_SIGNAL, ET_SIGNAL,
                               [ 'ZOMBIE' ], time(), __FILE__, __LINE__
                             );
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

  DEB_RELATION and do {
    die "session ", $session->ID, " already exists\a"
      if (exists $self->[KR_SESSIONS]->{$session});
  };

  $self->_dispatch_state( $session, $kr_active_session,
                          EN_START, ET_START, \@args,
                          time(), __FILE__, __LINE__, undef
                        );
  $self->_enqueue_state( $session, $kr_active_session, EN_GC, ET_GC,
                         [], time(), __FILE__, __LINE__
                       );
}

sub session_free {
  my ($self, $session) = @_;

  DEB_RELATION and do {
    die "session ", $session->ID, " doesn't exist\a"
      unless (exists $self->[KR_SESSIONS]->{$session});
  };

  $self->_dispatch_state( $session, $self->[KR_ACTIVE_SESSION],
                          EN_STOP, ET_STOP, [],
                          time(), __FILE__, __LINE__, undef
                        );
  $self->_collect_garbage($session);
}

sub _collect_garbage {
  my ($self, $session) = @_;
                                        # check for death by starvation
  if (($session ne $self) && (exists $self->[KR_SESSIONS]->{$session})) {

    my $ss = $self->[KR_SESSIONS]->{$session};

    DEB_GC and do {
      warn ",----- GC test for session ", $session->ID, " -----\n";
      warn "| ref. count    : $ss->[SS_REFCOUNT]\n";
      warn "| event count   : $ss->[SS_EVCOUNT]\n";
      warn "| child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n";
      warn "| handles in use: ", scalar(keys(%{$ss->[SS_HANDLES]})), "\n";
      warn "| aliases in use: ", scalar(keys(%{$ss->[SS_ALIASES]})), "\n";
      warn "`---------------------------------------------------\n";
      warn "<<< GARBAGE: $session\n" unless ($ss->[SS_REFCOUNT]);
    };

    DEB_REFCOUNT and do {
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
    };

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
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line
     ) = @_;

  my $state_to_queue =
    [ $session, $source_session,
      $state, $type, $etc, $time,
      $file, $line, ++$queue_seqnum,
    ];

  DEB_EVENTS and do {
    warn "}}} enqueuing $state for session ", $session->ID, "\n";
  };

  if (exists $self->[KR_SESSIONS]->{$session}) {
    my $kr_states = $self->[KR_STATES];

    # Special cases: No states in the queue.  Put the new state in the
    # queue, and be done with it.
    unless (@$kr_states) {
      $kr_states->[0] = $state_to_queue;
    }

    # Special case: New state belongs at the end of the queue.  Push
    # it, and be done with it.
    elsif ($time >= $kr_states->[-1]->[ST_TIME]) {
      push @$kr_states, $state_to_queue;
    }

    # Special case: New state comes before earliest state.  Unshift
    # it, and be done with it.
    elsif ($time < $kr_states->[0]->[ST_TIME]) {
      unshift @$kr_states, $state_to_queue;
    }

    # Special case: Two states in the queue.  The new state enters
    # between them.
    elsif (@$kr_states == 2) {
      splice(@$kr_states, 1, 0, $state_to_queue);
    }

    # Small queue.  Perform a reverse linear search on the assumption
    # that (a) a linear search is fast enough on small queues; and (b)
    # most events will be posted for "now" which tends to be towards
    # the end of the queue.
    elsif (@$kr_states < 32) {
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

    # And finally, we have this large queue, and the program has
    # already wasted enough time.
    else {
      my $upper = @$kr_states - 1;
      my $lower = 0;
      while ('true') {
        my $midpoint = ($upper + $lower) >> 1;

        DEB_INSERT and do {
          warn "<<<<< lo($lower)  mid($midpoint)  hi($upper) >>>>>\n";
        };

        # Upper and lower bounds crossed.  No match; insert at the
        # lower bound point.
        if ($upper < $lower) {
          DEB_INSERT and do {
            &debug_insert($kr_states, $lower, $time);
          };
          splice(@$kr_states, $lower, 0, $state_to_queue);
          last;
        }

        # The key at the midpoint is too high.  The element just below
        # the midpoint becomes the new upper bound.
        if ($time < $kr_states->[$midpoint]->[ST_TIME]) {
          $upper = $midpoint - 1;
          next;
        }

        # The key at the midpoint is too low.  The element just above
        # the midpoint becomes the new lower bound.
        if ($time > $kr_states->[$midpoint]->[ST_TIME]) {
          $lower = $midpoint + 1;
          next;
        }

        # The key matches the one at the midpoint.  Scan towards
        # higher keys until the midpoint points to an element with a
        # higher key.  Insert the new state before it.
        $midpoint++
          while ( ($midpoint < @$kr_states) 
                  and ($time == $kr_states->[$midpoint]->[ST_TIME])
                );
        DEB_INSERT and do {
          &debug_insert($kr_states, $midpoint, $time);
        };
        splice(@$kr_states, $midpoint, 0, $state_to_queue);
        last;
      }
    }

    $self->[KR_SESSIONS]->{$session}->[SS_EVCOUNT]++;
    $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT]++;

    DEB_REFCOUNT and do {
      warn("+++ enqueuing state for session ", $session->ID, ": ",
           $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT], "\n"
          );
    };
  }
  else {
    warn ">>>>> ", join('; ', keys(%{$self->[KR_SESSIONS]})), " <<<<<\n";
    warn "($$ = $etc->[0])";
    croak "can't enqueue state($state) for nonexistent session($session)\a\n";
  }
}

#------------------------------------------------------------------------------
# Post a state to the queue.

sub post {
  my ($self, $destination, $state_name, @etc) = @_;
  my ($file, $line) = (caller)[1,2];

  if (defined($destination = $self->alias_resolve($destination))) {
    $self->_enqueue_state( $destination, $self->[KR_ACTIVE_SESSION],
                           $state_name, ET_USER, \@etc, time(),
                           $file, $line
                         );
    return 1;
  }
  DEB_STRICT and do {
    warn "Cannot resolve alias $destination into a session\n";
    confess;
  };
  return undef;
}

#------------------------------------------------------------------------------
# Post a state to the queue for the current session.

sub yield {
  my ($self, $state_name, @etc) = @_;
  my ($file, $line) = (caller)[1,2];

  $self->_enqueue_state( $self->[KR_ACTIVE_SESSION],
                         $self->[KR_ACTIVE_SESSION],
                         $state_name, ET_USER, \@etc, time(),
                         $file, $line
                       );
}

#------------------------------------------------------------------------------
# Call a state directly.

sub call {
  my ($self, $destination, $state_name, @etc) = @_;
  my ($file, $line) = (caller)[1,2];

  if (defined($destination = $self->alias_resolve($destination))) {
    $! = 0;
    return $self->_dispatch_state( $destination,
                                   $self->[KR_ACTIVE_SESSION],
                                   $state_name, ET_USER, \@etc,
                                   time(), $file, $line, undef
                                 );
  }
  DEB_STRICT and do {
    warn "Cannot resolve alias $destination into session\n";
    confess;
  };
  return undef;
}

#------------------------------------------------------------------------------
# Peek at pending alarms.  Returns a list of pending alarms.

sub queue_peek_alarms {
  my ($self) = @_;
  my @pending_alarms;

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  my $state_count = $self->[KR_SESSIONS]->{$kr_active_session}->[SS_EVCOUNT];

  foreach my $state (@{$self->[KR_STATES]}) {
    last unless $state_count;
    next unless $state->[ST_SESSION] eq $kr_active_session;
    next unless $state->[ST_TYPE] & ET_ALARM;
    push @pending_alarms, $state->[ST_NAME];
    $state_count--;
  }

  @pending_alarms;
}

#==============================================================================
# DELAYED EVENTS
#==============================================================================

sub alarm {
  my ($self, $state, $time, @etc) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  my ($file, $line) = (caller)[1,2];
                                        # remove alarm (all instances)
  my $index = scalar(@{$self->[KR_STATES]});
  while ($index--) {
    if ( ($self->[KR_STATES]->[$index]->[ST_SESSION] eq $kr_active_session) &&
         ($self->[KR_STATES]->[$index]->[ST_TYPE] & ET_ALARM) &&
         ($self->[KR_STATES]->[$index]->[ST_NAME] eq $state)
    ) {
      $self->[KR_SESSIONS]->{$kr_active_session}->[SS_EVCOUNT]--;
      DEB_REFCOUNT and do {
        die if ($self->[KR_SESSIONS]->{$kr_active_session}->[SS_EVCOUNT] < 0);
      };
      $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT]--;
      DEB_REFCOUNT and do {
        warn("--- removing alarm for session ", $kr_active_session->ID, ": ",
             $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT], "\n"
            );
        die if ($self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT] < 0);
      };
      splice(@{$self->[KR_STATES]}, $index, 1);
    }
  }
                                        # add alarm (if non-zero time)
  if ($time) {
    if ($time < (my $now = time())) {
      $time = $now;
    }
    $self->_enqueue_state( $kr_active_session, $kr_active_session,
                           $state, ET_ALARM, [ @etc ], $time,
                           $file, $line
                         );
  }
}

# This will be a version of alarm that doesn't clobber existing ones.
sub alarm_add {
  my ($self, $state, $time, @etc) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  my ($file, $line) = (caller)[1,2];

  if ($time < (my $now = time())) {
    $time = $now;
  }
  $self->_enqueue_state( $kr_active_session, $kr_active_session,
                         $state, ET_ALARM, [ @etc ], $time,
                         $file, $line
                       );
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

# This will be a version of delay that doesn't clobber existing ones.
sub delay_add {
  my ($self, $state, $delay, @etc) = @_;
  if (defined $delay) {
    $self->alarm_add($state, time() + $delay, @etc);
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

# This depends heavily on socket.ph, or somesuch.  It's way
# unportable.  I can't begin to figure out a way to make this work
# everywhere, so I'm not even going to try.
#       setsockopt($handle, SOL_SOCKET, &TCP_NODELAY, 1)
#         or die "Couldn't disable Nagle's algorithm: $!\a\n";

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
      DEB_REFCOUNT and do {
        warn("+++ added select for session ", $session->ID, ": ",
             $kr_session->[SS_REFCOUNT], "\n"
            );
      };
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
        DEB_REFCOUNT and do {
          die if ($kr_handle->[HND_VECCOUNT]->[$select_index] < 0);
        };
        unless ($kr_handle->[HND_VECCOUNT]->[$select_index]) {
          vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 0;
        }
        $kr_handle->[HND_REFCOUNT]--;
        DEB_REFCOUNT and do {
          die if ($kr_handle->[HND_REFCOUNT] < 0);
        };
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
        DEB_REFCOUNT and do {
          die if ($ss_handle->[SH_REFCOUNT] < 0);
        };
        unless ($ss_handle->[SH_REFCOUNT]) {
          delete $kr_session->[SS_HANDLES]->{$handle};
          $kr_session->[SS_REFCOUNT]--;
          DEB_REFCOUNT and do {
            warn("--- removed select for session ", $session->ID, ": ",
                 $kr_session->[SS_REFCOUNT], "\n"
                );
            die if ($kr_session->[SS_REFCOUNT] < 0);
          };
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

sub select_pause_write {
  my ($self, $handle) = @_;

  # Don't bother if the kernel isn't tracking the handle.
  return 0 unless exists $self->[KR_HANDLES]->{$handle};

  # Don't bother if the kernel isn't tracking the handle's write status.
  return 0 unless $self->[KR_HANDLES]->{$handle}->[HND_VECCOUNT]->[VEC_WR];

  # Turn off the select vector's write bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.

  vec($self->[KR_VECTORS]->[VEC_WR], fileno($handle), 1) = 0;
  return 1;
}

sub select_resume_write {
  my ($self, $handle) = @_;

  # Don't bother if the kernel isn't tracking the handle.
  return 0 unless exists $self->[KR_HANDLES]->{$handle};

  # Don't bother if the kernel isn't tracking the handle's write status.
  return 0 unless $self->[KR_HANDLES]->{$handle}->[HND_VECCOUNT]->[VEC_WR];

  # Turn off the select vector's write bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.

  vec($self->[KR_VECTORS]->[VEC_WR], fileno($handle), 1) = 1;
  return 1;
}

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
  DEB_REFCOUNT and do {
    warn("+++ added alias for session ", $kr_active_session->ID, ": ",
         $self->[KR_SESSIONS]->{$kr_active_session}->[SS_REFCOUNT], "\n"
        );
  };
  return 1;
}

sub _internal_alias_remove {
  my ($self, $session, $name) = @_;
  delete $self->[KR_ALIASES]->{$name};
  delete $self->[KR_SESSIONS]->{$session}->[SS_ALIASES]->{$name};
  $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT]--;
  DEB_REFCOUNT and do {
    warn("--- removed alias for session ", $session->ID, ": ",
         $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT], "\n"
        );
    die if ($self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT] < 0);
  };
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
  return $self->[KR_SESSIONS]->{$name}->[SS_SESSION]
    if exists $self->[KR_SESSIONS]->{$name};
                                        # resolve against IDs
  return $self->[KR_SESSION_IDS]->{$name}
    if exists $self->[KR_SESSION_IDS]->{$name};
                                        # resolve against aliases
  return $self->[KR_ALIASES]->{$name}
    if exists $self->[KR_ALIASES]->{$name};
                                        # resolve against current namespace
  if ($self->[KR_ACTIVE_SESSION] ne $self) {
    if ($name eq $self->[KR_ACTIVE_SESSION]->[&POE::Session::SE_NAMESPACE]) {
      carp "Using HEAP instead of SESSION is depreciated";
      return $self->[KR_ACTIVE_SESSION];
    }
  }
                                        # resolve against the kernel
  return $self if ($name eq $self);
                                        # it doesn't resolve to anything?
  $! = ESRCH;
  return undef;
}

#==============================================================================
# Kernel ID
#==============================================================================

sub ID {
  my $self = shift;
  $self->[KR_ID];
}

sub ID_id_to_session {
  my ($self, $id) = @_;
  if (exists $self->[KR_SESSION_IDS]->{$id}) {
    $! = 0;
    return $self->[KR_SESSION_IDS]->{$id};
  }
  $! = ESRCH;
  return undef;
}

sub ID_session_to_id {
  my ($self, $session) = @_;
  if (exists $self->[KR_SESSIONS]->{$session}) {
    $! = 0;
    return $self->[KR_SESSIONS]->{$session}->[SS_ID];
  }
  $! = ESRCH;
  return undef;
}

#==============================================================================
# Safe fork and SIGCHLD.
#==============================================================================

sub fork {
  my ($self) = @_;
  my ($file, $line) = (caller)[1,2];

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
      $self->_enqueue_state( $self, $self, EN_SCPOLL, ET_SCPOLL,
                             [], time() + 1, $file, $line
                           );
    }

    return( $new_pid, 0, 0 ) if wantarray;
    return $new_pid;
  }

  # Child.
  else {

    # Build a list of unique sessions with children.
    my %sessions;
    foreach (values %{$self->[KR_PROCESSES]}) {
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
  my ($self, $state_name, $state_code, $state_alias) = @_;
  $state_alias = $state_name unless defined $state_alias;

  if ( (ref($self->[KR_ACTIVE_SESSION]) ne '') &&
                                        # -><- breaks subclasses... sky has fix
       (ref($self->[KR_ACTIVE_SESSION]) ne 'POE::Kernel')
  ) {
    $self->[KR_ACTIVE_SESSION]->register_state( $state_name, $state_code,
                                                $state_alias
                                              );
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
  print $poe_kernel->ID(); # This process' unique ID.
  new POE::Session( ... ); # Bootstrap sessions are here.
  $poe_kernel->run();      # Run the kernel.
  exit;                    # Exit when the kernel's done.

  # Session management methods:
  $kernel->session_create( ... );

  # Event management methods:
  $kernel->post( $session, $state, @args );
  $kernel->yield( $state, @args );
  $state_retval = $kernel->call( $session, $state, @args );
  @alarms = $kernel->queue_peek_alarms( );

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
  $kernel->select_pause_write( $file_handle );
  $kernel->select_resume_write( $file_handle );

  # Signals:
  $kernel->sig( $signal_name, $state_name ); # Registers a handler.
  $kernel->signal( $session, $signal_name ); # Posts a signal.

  # Processes.
  $fork_retval = $kernel->fork();   # "Safe" fork that polls for SIGCHLD.

  # States:
  $kernel->state( $state_name, $code_reference );    # Inline state
  $kernel->state( $method_name, $object_reference ); # Object state
  $kernel->state( $function_name, $package_name );   # Package state
  $kernel->state( $state_name,                       # Object or package
                  $object_or_package_reference,      #  state, mapped to
                  $object_or_package_method,         #  different method.
                );

  # IDs:
  $id = $kernel->ID();                       # Return the Kernel's unique ID.
  $id = $kernel->alias_resolve($id);         # Return undef, or a session.
  $id = $kernel->ID_session_to_id($session); # Return undef, or a session's ID.

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

Some Kernel methods accept a C<$session> reference.  These allow
events to be dispatched to arbitrary sessions.  For example, a program
can post a state transition event almost anywhere:

  $kernel->post( $destination_session, $state_to_invoke );

On the other hand, there are methods that don't let programs specify
destinations.  The events generated by these methods, if any, will be
dispatched to the current session.  For example, setting an alarm:

  $kernel->alarm( $state_to_invoke, $when_to_invoke_it );

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

=item *

POE::Kernel::queue_peek_alarms()

Peeks at the current session's event queue, returning a list of
pending alarms.  The list is empty if no alarms are pending.  The
list's order is undefined as of version 0.0904 (it's really in time
order, but that may change).

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

The alarm() method enqueues an event for the current session with a
future dispatch time, specified in seconds since whatever epoch time()
uses (usually the UNIX epoch).  If $time is in the past, it will be
clipped to time(), making the alarm() call synonymous to post() but
with some extra overhead.

alarm() ensures that its alarm is the only one queued for the current
session and given state.  It does this by scouring the queue and
removing all others matching the combination of session and state.  As
of 0.0908, the alarm_add() method can post additional alarms without
scouring previous ones away.

@args are passed to the alarm handler as C<@_[ARG0..$#_]>.

It is possible to remove alarms from the queue by posting an alarm
without additional parameters.  This triggers the queue scour without
posting an alarm.  For example:

  $kernel->alarm( $state ); # Removes the alarm for $state

As of version 0.0904, the alarm() function will only remove alarms.
Other types of events will remain in the queue.

=item *

POE::Kernel::alarm_add( $state, $time, @args )

The alarm_add() method enqueues an event for the current session with
a future dispatch time, specified in seconds since whatever epoch
time() uses (usually the UNIX epoch).  If $time is in the past, it
will be clipped to time(), making the alarm_add() call synonymous to
post() but with some extra overhead.

Unlike alarm(), however, it does not scour the queue for previous
alarms matching the current session/state pair.  Since it doesn't
scour, adding an empty alarm won't clear others from the queue.

This function may be faster than alarm() since the scour phase is
skipped.

=item *

POE::Kernel::delay( $state, $seconds, @args )

The delay() method is an alias for:

  $kernel->alarm( $state, time() + $seconds, @args );

However it silently uses Time::HiRes if it's available, so time()
automagically has an increased resolution when it can.  This saves
programs from having to figure out whether Time::HiRes is available
themselves.

All the details for POE::Kernel::alarm() apply to delay() as well.
For example, delays may be removed by omitting the $seconds and @args
parameters:

  $kernel->delay( $state ); # Removes the delay for $state

As of version 0.0904, the delay() function will only remove alarms.
Other types of events will remain in the queue.

=item *

POE::Kernel::delay_add( $state, $seconds, @args )

The delay_add() method works like delay(), but it allows duplicate
alarms.  It is equivalent to:

  $kernel->alarm_add( $state, time() + $seconds, @args );

The "empty delay" syntax is meaningless since alarm_add() does not
scour the queue for duplicates.

This function may be faster than delay() since the scour phase is
skipped.

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

$kernel->alias_resolve($alias) has been overloaded to resolve several
things into session references.  Each of these things may be used
instead of a session reference in other kernel method calls.

The things, in order, are:

Session references: Yes, this is redundant, but it also means that you
can use stringified session references as event destinations.  That
provides a form of weak session reference, which can be handy, but
note: Perl reuses references rather quickly, so programs should
probably use session IDs instead.

Session IDs: Every session is given a unique numeric ID, similar to an
operating system's process ID.  There never will be two sessions with
the same ID at the same time, and the rate of reuse is extremely low
(the ID is a Perl integer, which tends to be really really large).
These supply a different sort of weak reference for sessions.

Aliases: These are the ones registered by alias_set.

Heap references: Once upon a time $_[HEAP] was used in place of
$_[SESSION].  This is SEVERELY depreciated now, and programs will spew
warnings every time it's done.

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
POE::Kernel::select_write( $filehandle, $write_state )
POE::Kernel::select_expedite( $filehandle, $expedite_state )

These methods add, remove or change the state that is called when a
filehandle becomes ready for reading, writing, or out-of-band reading,
respectively.  They work like POE::Kernel::select, except they allow
individual aspects of a filehandle to be changed.

If the state parameter is undefined, then the filehandle watcher is
removed; otherwise it's added or changed.  These functions have a
moderate amount of overhead, since they update POE::Kernel's
reference-counting structures.

=item *

POE::Kernel::select_pause_write( $filehandle );
POE::Kernel::select_resume_write( $filehandle );

These methods allow a write select to be paused and resumed without
the overhead of maintaining POE::Kernel's reference-counting
structures.

It is most useful for write select handlers that may need to pause
write-okay events when their outbound buffers are empty and resume
them when new output is enqueued.

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

POE::Kernel::signal( $session, $signal_name, @args )

The signal() method posts a signal event to a session.  It uses the
kernel's event queue, bypassing the operating system, so the signal's
name is not limited to what the OS allows.  For example, the kernel
does something similar to post a fictitious ZOMBIE signal:

  $kernel->signal($session, 'ZOMBIE');

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
POE::Kernel::state( $state_name, $obj_or_package_ref, $method_name )

The state() method has three different uses, each for adding, updating
or removing a different kind of state.  It manipulates states in the
current session.

The three-parameter version of state() registers an object or package
state to a method with a different name.  Normally the object or
package method would need to be named after the state it catches.

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

They can also be maintained with:

  $kernel->state($state_name, $object_reference, $object_method);

For example, this maps a session's B®_start¯ state to the object's
start_state method:

  $kernel->state('_start', $object_reference, 'start_state');

=item *

Package States

Package states are manipulated with:

  $kernel->state($function_name, $package_name);

If $package_name is undef, then the $function_name state will be
removed.  Any pending events destined for $function_name will be
redirected to _default.

=back

=back

=head2 ID Management Methods

POE generates a unique ID for the process, and it maintains unique
serial numbers for every session.  These functions retrieve various ID
values.

=over 4

=item *

POE::Kernel::ID()

Returns a unique ID for this POE process.

  my $process_id = $kernel->ID();

=item *

POE::Kernel::ID_id_to_session( $id );

This function is depreciated.  Please see alias_resolve.

Returns a session reference for the given ID.  It returns undef if the
ID doesn't exist.  This allows programs to uniquely identify a
particular Session (or detect that it's gone) even if Perl reuses the
Session reference later.

=item *

POE::Kernel::ID_session_to_id( $session );

Returns an ID for the given POE::Session reference, or undef ith the
session doesn't exist.

Perl reuses Session references fairly frequently, but Session IDs are
unique.  Because of this, the ID of a given reference (stringified, so
Perl can release the referenced Session) may appear to change.  If it
does appear to have changed, then the Session reference is probably
invalid.

=back

=head1 DEBUGGING FLAGS

These flags were made public in 0.0906.  If they are pre-defined by
the first package that uses POE::Kernel (or POE, since that includes
POE::Kernel by default), then the pre-definition will take precedence
over POE::Kernel's definition.  In this way, it is possible to use
POE::Kernel's internal debugging code without finding Kernel.pm and
editing it.

Debugging flags are meant to be constants.  They should be prototyped
as such, and they must be declared in the POE::Kernel package.

Sample usage:

  # Display information about garbage collection, and display some
  # profiling information at the end.
  sub POE::Kernel::DEB_GC      () { 1 }
  sub POE::Kernel::DEB_PROFILE () { 1 }
  use POE;
  ...

=over 4

=item *

DEB_EVENTS

Enables a trace of events as they are enqueued and dispatched (or
discarded).  Also shows states' return values.

=item *

DEB_GC

Enables sanity checks in POE's internal structure cleanup, after each
Session is stopped, and again at the end of the program's run.
Displays the results of sessions' garbage-collection checks, perhaps
showing why a session isn't stopping when it ought to.

=item *

DEB_INSERT

Trace the steps POE::Kernel->_enqueue_state() takes to find the
locations of new events in its queue.

=item *

DEB_MAIN

The first debugging constant.  Prints "POE stopped." when
POE::Kernel->run() stops.

=item *

DEB_PROFILE

When enabled, POE::Kernel collects a histogram of state names that
were dispatched, and displays a report of them when POE::Kernel->run()
stops.

=item *

DEB_QUEUE

When enabled, POE::Kernel displays information about events in the
queue.

=item *

DEB_REFCOUNT

Enabling enables sanity checks and status displays on the number of
references POE::Kernel holds on resources.  These references are used
to determine when things like filehandles are no longer being used.

=item *

DEB_RELATION

Enabling this causes POE::Kernel to examine parent/child relationships
for problems.

=item *

DEB_SELECT

When enabled, DEB_SELECT causes POE::Kernel to display running
statistics about its select vectors and time-out status.

=item *

DEB_STRICT

When enabled, POE::Kernel->post() and POE::Kernel->call() must be able
to resolve an event's destination at post time.

=back

=head1 SEE ALSO

POE; POE::Session

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
