#!/usr/bin/perl -w

use strict;
package POE::Wheel::Curses;

use Carp qw(croak);
use Curses;
use POE qw(Wheel);

sub SELF_STATE_READ  () { 0 }
sub SELF_STATE_WRITE () { 1 }
sub SELF_EVENT_INPUT () { 2 }
sub SELF_ID          () { 3 }

sub new {
  my $type = shift;
  my %params = @_;

  croak "$type needs a working Kernel" unless defined $poe_kernel;

  my $input_event = delete $params{InputEvent};
  croak "$type requires an InputEvent parameter" unless defined $input_event;

  if (scalar keys %params) {
    carp( "unknown parameters in $type constructor call: ",
          join(', ', keys %params)
        );
  }

  # Create the object.
  my $self = bless
    [ undef,                            # SELF_STATE_READ
      undef,                            # SELF_STATE_WRITE
      $input_event,                     # SELF_EVENT_INPUT
      &POE::Wheel::allocate_wheel_id(), # SELF_ID
    ];

  # Set up the screen, and enable color, mangle the terminal and
  # keyboard.

  initscr();
  start_color();
  keypad(1);
  cbreak();
  noecho();
  raw();
  nonl();
  intrflush(0);
  nodelay(1);

  my $old_mouse_events = 0;
  mousemask(ALL_MOUSE_EVENTS, $old_mouse_events);

  noutrefresh();
  doupdate();

  # Define the input event.
  $self->_define_input_state();

  # Oop! Return ourself.  I forgot to do this.
  $self;
}

sub _define_input_state {
  my $self = shift;

  # Register the select-read handler.
  if (defined $self->[SELF_EVENT_INPUT]) {
    # Stupid closure tricks.
    my $event_input = \$self->[SELF_EVENT_INPUT];
    my $unique_id   = $self->[SELF_ID];

    $poe_kernel->state
      ( $self->[SELF_STATE_READ] = $self . ' select read',
        sub {

          # Prevents SEGV in older Perls.
          0 && CRIMSON_SCOPE_HACK('<');

          my ($k, $me) = @_[KERNEL, SESSION];

          # Curses' getch() normally blocks, but we've already
          # determined that STDIN has something for us.  Be explicit
          # about which getch() to use.
          while ((my $keystroke = Curses::getch) ne '-1') {
            $k->call( $me, $$event_input, $keystroke, $unique_id );
          }
        }
      );

    # Now start reading from it.
    $poe_kernel->select_read( *STDIN, $self->[SELF_STATE_READ] );
  }
  else {
    $poe_kernel->select_read( *STDIN );
  }
}

sub DESTROY {
  my $self = shift;

  # Turn off the select.
  $poe_kernel->select( *STDIN );

  # Remove states.
  if ($self->[SELF_STATE_READ]) {
    $poe_kernel->state($self->[SELF_STATE_READ]);
    $self->[SELF_STATE_READ] = undef;
  }

  # Restore the terminal.
  endwin if COLS;

  &POE::Wheel::free_wheel_id($self->[SELF_ID]);
}

###############################################################################
1;

__END__

... todo: documentation ...
