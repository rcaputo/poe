# $Id$

package POE::Wheel::ReadLine;

use strict;
use Carp;
use POE qw(Wheel);

# Things we'll need to interact with the terminal.
use Term::Cap;
use Term::ReadKey;

my $termcap;      # Termcap entry.
my $tc_bell;      # How to ring the terminal.
my %meta_prefix;  # Keystroke meta-prefixes.
my $tc_has_ke;    # Termcap can clear to end of line.

# Keystrokes.
my ( $tck_up, $tck_down, $tck_left, $tck_right, $tck_insert,
     $tck_delete, $tck_home, $tck_end, $tck_backspace
   );

# Screen extent.
my ($trk_rows, $trk_cols);

# Offsets into $self.
sub SELF_INPUT          () {  0 }
sub SELF_CURSOR_INPUT   () {  1 }
sub SELF_EVENT_INPUT    () {  2 }
sub SELF_READING_LINE   () {  3 }
sub SELF_STATE_READ     () {  4 }
sub SELF_PROMPT         () {  5 }
sub SELF_HIST_LIST      () {  6 }
sub SELF_HIST_INDEX     () {  7 }
sub SELF_INPUT_HOLD     () {  8 }
sub SELF_KEY_BUILD      () {  9 }
sub SELF_INSERT_MODE    () { 10 }
sub SELF_PUT_MODE       () { 11 }
sub SELF_PUT_BUFFER     () { 12 }
sub SELF_IDLE_TIME      () { 13 }
sub SELF_STATE_IDLE     () { 14 }
sub SELF_HAS_TIMER      () { 15 }
sub SELF_CURSOR_DISPLAY () { 16 }

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------
# Helper functions.

# Build a hash of input characters and their "normalized" display
# versions.  ISO Latin-1 characters (8th bit set "ASCII") are
# mishandled.  European users, please forgive me.  If there's a good
# way to handle this-- perhaps this is an interesting use for
# Unicode-- please let me know.

my (%normalized_character, @normalized_extra_width);
BEGIN {
  for (my $ord = 0; $ord < 256; $ord++) {
    $normalized_extra_width[$ord] =
      length
        ( $normalized_character{chr($ord)} =
          ( ($ord > 126)
            ? (sprintf "<%2x>", $ord)
            : ( ($ord > 31)
                ? chr($ord)
                : ( '^' . chr($ord+64) )
              )
          )
        ) - 1;
  }
};

# Return a normalized version of a string.  This includes destroying
# 8th-bit-set characters, turning them into strange multi-byte
# sequences.  Apologies to everyone; please let me know of a portable
# way to deal with this.
sub normalize {
  local $_ = shift;
  s/([^ -~])/$normalized_character{$1}/g;
  return $_;
}

# Calculate the display width of a string.  The display width is
# sometimes wider than the actual string because some characters are
# represented on the terminal as multiple characters.

sub display_width {
  local $_ = shift;
  my $width = length;
  $width += $normalized_extra_width[ord] foreach (m/([\x00-\x1F\x7F-\xFF])/g);
  return $width;
}

# Some keystrokes generate multi-byte sequences.  Record the prefixes
# for multi-byte sequences so the keystroke builder knows it's in the
# middle of something.
sub meta {
  foreach (@_) {
    my $meta = $_;
    while (length($meta) > 1) {
      chop $meta;
      $meta_prefix{$meta} = 1;
    }
  }
}

# Preprocess a keystroke.  This gets it from the termcap, handles
# meta-prefixes, and returns its normalized version.
sub preprocess_keystroke {
  my $termcap_tag = shift;
  my $keystroke = $termcap->Tputs( $termcap_tag, 1 );
  meta( $keystroke );
  normalize( $keystroke );
}

# One-time setup.
BEGIN {
  # Get the terminal speed for Term::Cap.
  my $termios = POSIX::Termios->new();
  $termios->getattr();
  my $ospeed = $termios->getospeed();

  # Get the current terminal's capabilities.
  $termcap = Term::Cap->Tgetent( { TERM => undef, OSPEED => $ospeed } );
  die "could not determine terminal capabilities: $!" unless defined $termcap;

  # Require certain capabilites.
  $termcap->Trequire( qw( LE RI cl ku kd kl kr ) );

  # Some things are optional.
  eval { $termcap->Trequire( 'kE' ) };
  $tc_has_ke = 1 unless $@;

  # o/` You can ring my bell, ring my bell. o/`
  my $bell = $termcap->Tputs( bl => 1 );
  $bell = $termcap->Tputs( vb => 1 ) unless defined $bell;
  $tc_bell = (defined $bell) ? $bell : '';

  # Arrow keys.  These are required.
  $tck_up    = preprocess_keystroke( 'ku' );
  $tck_down  = preprocess_keystroke( 'kd' );
  $tck_left  = preprocess_keystroke( 'kl' );
  $tck_right = preprocess_keystroke( 'kr' );

  # Insert key.
  eval { $termcap->Trequire( 'kI' ) };
  if ($@) { $tck_insert = '';                           }
  else    { $tck_insert = preprocess_keystroke( 'kI' ); }

  # Delete key.
  eval { $termcap->Trequire( 'kD' ) };
  if ($@) { $tck_delete = '';                           }
  else    { $tck_delete = preprocess_keystroke( 'kD' ); }

  # Home key.
  eval { $termcap->Trequire( 'kh' ) };
  if ($@) { $tck_home = '';                           }
  else    { $tck_home = preprocess_keystroke( 'kh' ); }

  # End key.
  eval { $termcap->Trequire( 'kH' ) };
  if ($@) { $tck_end = '';                           }
  else    { $tck_end = preprocess_keystroke( 'kH' ); }

  # Backspace key.
  eval { $termcap->Trequire( 'kb' ) };
  if ($@) { $tck_backspace = '';                           }
  else    { $tck_backspace = preprocess_keystroke( 'kb' ); }

  # Terminal size.
  ($trk_cols, $trk_rows) = Term::ReadKey::GetTerminalSize(*STDOUT);

  # Esc is the generic meta prefix.
  $meta_prefix{chr(27)} = 1;
};

#------------------------------------------------------------------------------
# The methods themselves.

# Create a new ReadLine wheel.
sub new {
  my $type = shift;

  my %params = @_;
  croak "$type requires a working Kernel" unless defined $poe_kernel;

  my $input_event = delete $params{InputEvent};
  croak "$type requires an InputEvent parameter" unless defined $input_event;

  my $put_mode = delete $params{PutMode};
  $put_mode = 'idle' unless defined $put_mode;
  croak "$type PutMode must be either 'immediate', 'idle', or 'after'"
    unless $put_mode =~ /^(immediate|idle|after)$/;

  my $idle_time = delete $params{IdleTime};
  $idle_time = 2 unless defined $idle_time;

  my $self = bless
    [ '',           # SELF_INPUT
      0,            # SELF_CURSOR_INPUT
      $input_event, # SELF_EVENT_INPUT
      0,            # SELF_READING_LINE
      undef,        # SELF_STATE_READ
      '>',          # SELF_PROMPT
      [ ],          # SELF_HIST_LIST
      0,            # SELF_HIST_INDEX
      '',           # SELF_INPUT_HOLD
      '',           # SELF_KEY_BUILD
      1,            # SELF_INSERT_MODE
      $put_mode,    # SELF_PUT_MODE
      [ ],          # SELF_PUT_BUFFER
      $idle_time,   # SELF_IDLE_TIME
      undef,        # SELF_STATE_IDLE
      0,            # SELF_HAS_TIMER
      0,            # SELF_CURSOR_DISPLAY
    ], $type;

  if (scalar keys %params) {
    carp( "unknown parameters in $type constructor call: ",
          join(', ', keys %params)
        );
  }

  # Turn off STDOUT buffering.
  select((select(STDOUT), $| = 1)[0]);

  # Set up console using Term::ReadKey.
  ReadMode('ultra-raw');

  # Set up the event handlers.  Idle goes first.
  $self->_define_idle_state();
  $self->_define_read_state();

  return $self;
}

#------------------------------------------------------------------------------
# Destroy the ReadLine wheel.  Clean up the terminal.

sub DESTROY {
  my $self = shift;

  # Stop selecting on the handle.
  $poe_kernel->select( *STDIN );

  # Detach our tentacles from the parent session.
  if ($self->[SELF_STATE_READ]) {
    $poe_kernel->state($self->[SELF_STATE_READ]);
    $self->[SELF_STATE_READ] = undef;
  }

  if ($self->[SELF_STATE_IDLE]) {
    $poe_kernel->alarm($self->[SELF_STATE_IDLE]);
    $poe_kernel->state($self->[SELF_STATE_IDLE]);
    $self->[SELF_STATE_IDLE] = undef;
  }

  # Restore the console.
  ReadMode('restore');
}

#------------------------------------------------------------------------------
# Redefine the idle handler.  This also uses stupid closure tricks.
# See the comments for &_define_read_state for more information about
# these closure tricks.

sub _define_idle_state {
  my $self = shift;

  my $has_timer   = \$self->[SELF_HAS_TIMER];
  my $put_buffer  = $self->[SELF_PUT_BUFFER];

  # This handler is called when input has become idle.
  $poe_kernel->state
    ( $self->[SELF_STATE_IDLE] = $self . ' input timeout',
      sub {
        # Prevents SEGV in older Perls.
        0 && CRIMSON_SCOPE_HACK('<');

        my ($k, $s) = @_[KERNEL, SESSION];

        if (@$put_buffer) {
          $self->_wipe_input_line();
          $self->_flush_output_buffer();
          $self->_repaint_input_line();
        }

        # No more timer.
        $$has_timer = 0;
      }
    );
}

#------------------------------------------------------------------------------
# Redefine the select-read handler.  This uses stupid closure tricks
# to prevent keeping extra references to $self around.

sub _define_read_state {
  my $self = shift;

  # Register the select-read handler.
  if (defined $self->[SELF_EVENT_INPUT]) {

    # If any of these change, then the read state is invalidated and
    # needs to be redefined.  Things which are read-only are assigned
    # by value.  Things that need to be read/write are assigned by
    # reference, so that changing them within the state modifies $self
    # without holding a reference to $self.
    my $input_hold     = \$self->[SELF_INPUT_HOLD];
    my $input          = \$self->[SELF_INPUT];
    my $cursor_input   = \$self->[SELF_CURSOR_INPUT];
    my $event_input    = \$self->[SELF_EVENT_INPUT];
    my $reading        = \$self->[SELF_READING_LINE];
    my $prompt         = \$self->[SELF_PROMPT];
    my $hist_list      = $self->[SELF_HIST_LIST];       # already a listref
    my $hist_index     = \$self->[SELF_HIST_INDEX];
    my $key_build      = \$self->[SELF_KEY_BUILD];
    my $insert_mode    = \$self->[SELF_INSERT_MODE];
    my $cursor_display = \$self->[SELF_CURSOR_DISPLAY];

    my $state_idle     = $self->[SELF_STATE_IDLE];
    my $idle_time      = $self->[SELF_IDLE_TIME];
    my $has_timer      = \$self->[SELF_HAS_TIMER];
    my $put_buffer     = $self->[SELF_PUT_BUFFER];
    my $put_mode       = $self->[SELF_PUT_MODE];

    $poe_kernel->state
      ( $self->[SELF_STATE_READ] = $self . ' select read',
        sub {

          # Prevents SEGV in older Perls.
          0 && CRIMSON_SCOPE_HACK('<');

          my ($k, $s) = @_[KERNEL, SESSION];

          # Read keys, non-blocking, as long as there are some.
          while (defined(my $key = ReadKey(-1))) {

            # Not reading a line; discard the input.
            next unless $$reading;

            # Update the timer on significant input.
            if ( $put_mode eq 'idle' ) {
              $k->delay( $state_idle, $idle_time );
              $$has_timer = 1;
            }

            # Keep glomming keystrokes until they stop existing in the
            # hash of meta prefixes.
            $$key_build .= $key;
            next if exists $meta_prefix{$$key_build};

            # Make the keystroke printable.
            $key = normalize(my $raw_key = $$key_build);
            $$key_build = '';

            # Skip test for meta-keys if the keystroke's length is
            # just one character.
            if (length($key) > 1) {

              # Beginning of line.
              if ( $key eq '^A' or $key eq $tck_home ) {
                if ($$cursor_input) {
                  $termcap->Tgoto( 'LE', 1, $$cursor_display, *STDOUT );
                  $$cursor_display = $$cursor_input = 0;
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Back one character.
              if ($key eq '^B' or $key eq $tck_left) {
                if ($$cursor_input) {
                  $$cursor_input--;
                  my $left = display_width(substr($$input, $$cursor_input, 1));
                  $termcap->Tgoto( 'LE', 1, $left, *STDOUT );
                  $$cursor_display -= $left;
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Interrupt.
              if ($key eq '^C') {
                print $key, "\x0D\x0A";
                $poe_kernel->select_read( *STDIN );
                if ($$has_timer) {
                  $k->delay( $state_idle );
                  $$has_timer = 0;
                }
                $poe_kernel->yield( $$event_input, undef, 'interrupt' );
                $$reading = 0;
                $$hist_index = @$hist_list;
                $self->_flush_output_buffer();
                next;
              }

              # Delete a character.
              if ( $key eq '^D' or $key eq $tck_delete ) {
                if ($$cursor_input < length($$input)) {
                  my $kill_width =
                    display_width(substr($$input, $$cursor_input, 1));
                  substr( $$input, $$cursor_input, 1 ) = '';
                  my $normal =
                    ( normalize(substr($$input, $$cursor_input)) .
                      (' ' x $kill_width)
                    );
                  print $normal;
                  $termcap->Tgoto( 'LE', 1, length($normal), *STDOUT );
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # End of line.
              if ( $key eq '^E' or $key eq $tck_end ) {
                if ($$cursor_input < length($$input)) {
                  my $right = display_width(substr($$input, $$cursor_input));
                  $termcap->Tgoto( 'RI', 1, $right, *STDOUT );
                  $$cursor_display += $right;
                  $$cursor_input = length($$input);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Forward character.
              if ($key eq '^F' or $key eq $tck_right) {
                if ($$cursor_input < length($$input)) {
                  my $normal = normalize(substr($$input, $$cursor_input, 1));
                  print $normal;
                  $$cursor_input++;
                  $$cursor_display += length($normal);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Cancel.
              if ($key eq '^G') {
                print $key, "\x0D\x0A";
                $poe_kernel->select_read( *STDIN );
                if ($$has_timer) {
                  $k->delay( $state_idle );
                  $$has_timer = 0;
                }
                $poe_kernel->yield( $$event_input, undef, 'cancel' );
                $$reading = 0;
                $$hist_index = @$hist_list;
                $self->_flush_output_buffer();
                return;
              }

              # Backward delete character.
              if ($key eq '^H' or $key eq $tck_backspace) {
                if ($$cursor_input) {
                  $$cursor_input--;
                  my $left = display_width(substr($$input, $$cursor_input, 1));
                  my $kill_width =
                    display_width(substr($$input, $$cursor_input, 1));
                  substr($$input, $$cursor_input, 1) = '';
                  $termcap->Tgoto( 'LE', 1, $left, *STDOUT );
                  my $normal =
                    ( normalize(substr($$input, $$cursor_input)) .
                      (' ' x $kill_width)
                    );
                  print $normal;
                  $termcap->Tgoto( 'LE', 1, length($normal), *STDOUT );
                  $$cursor_display -= $kill_width;
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Accept line.
              if ($key eq '^J') {
                print "\x0D\x0A";
                $poe_kernel->select_read( *STDIN );
                if ($$has_timer) {
                  $k->delay( $state_idle );
                  $$has_timer = 0;
                }
                $poe_kernel->yield( $$event_input, $$input );
                $$reading = 0;
                $$hist_index = @$hist_list;
                $self->_flush_output_buffer();
                next;
              }

              # Kill to EOL.
              if ($key eq '^K') {
                if ($$cursor_input < length($$input)) {
                  my $kill_width =
                    display_width(substr($$input, $$cursor_input));
                  substr( $$input, $$cursor_input ) = '';
                  print( (" " x $kill_width),
                         $termcap->Tgoto( 'LE', 1, $kill_width )
                       );
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Clear screen.
              if ($key eq '^L') {
                my $left = display_width(substr($$input, $$cursor_input));
                $termcap->Tputs( 'cl', 1, *STDOUT );
                print $$prompt, normalize($$input);
                $termcap->Tgoto( 'LE', 1, $left, *STDOUT ) if $left;
                next;
              }

              # Accept line.
              if ($key eq '^M') {
                print "\x0D\x0A";
                $poe_kernel->select_read( *STDIN );
                if ($$has_timer) {
                  $k->delay( $state_idle );
                  $$has_timer = 0;
                }
                $poe_kernel->yield( $$event_input, $$input );
                $$reading = 0;
                $$hist_index = @$hist_list;
                $self->_flush_output_buffer();
                next;
              }

              # Transpose characters.
              if ($key eq '^T') {
                if ($$cursor_input > 0 and $$cursor_input < length($$input)) {
                  my $width_left =
                    display_width(substr($$input, $$cursor_input - 1, 1));

                  my $transposition =
                    reverse substr($$input, $$cursor_input - 1, 2);
                  substr($$input, $$cursor_input - 1, 2) = $transposition;

                  $termcap->Tgoto( 'LE', 1, $width_left, *STDOUT );
                  print normalize($transposition);
                  $termcap->Tgoto( 'LE', 1, $width_left, *STDOUT );
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Discard line.
              if ($key eq '^U') {
                if (length $$input) {

                  # Back up to the beginning of the line.
                  if ($$cursor_input) {
                    print $termcap->Tgoto( 'LE', 1, $$cursor_display );
                    $$cursor_display = $$cursor_input = 0;
                  }

                  # Clear to the end of the line.
                  if ($tc_has_ke) {
                    print $termcap->Tputs( 'kE', 1 );
                  }
                  else {
                    my $display_width = display_width($$input);
                    print ' ' x $display_width;
                    $termcap->Tgoto( 'LE', 1, $display_width, *STDOUT );
                  }

                  # Clear the input buffer.
                  $$input = '';
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Word rubout.
              if ($key eq '^W' or $key eq '^[^H') {
                if ($$cursor_input) {

                  # Delete the word, and back up the cursor.
                  substr($$input, 0, $$cursor_input) =~ s/(\S*\s*)$//;
                  $$cursor_input -= length($1);

                  # Back up the screen cursor; show the line's tail.
                  my $delete_width = display_width($1);
                  $termcap->Tgoto( 'LE', 1, $delete_width, *STDOUT );
                  print normalize(substr( $$input, $$cursor_input ));

                  # Clear to the end of the line.
                  if ($tc_has_ke) {
                    print $termcap->Tputs( 'kE', 1 );
                  }
                  else {
                    print ' ' x $delete_width;
                    $termcap->Tgoto( 'LE', 1, $delete_width, *STDOUT );
                  }

                  # Back up the screen cursor to match the edit one.
                  if (length($$input) != $$cursor_input) {
                    my $display_width =
                      display_width( substr($$input, $$cursor_input) );
                    $termcap->Tgoto( 'LE', 1, $display_width, *STDOUT );
                  }
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Previous in history.
              if ($key eq '^P' or $key eq $tck_up) {
                if ($$hist_index) {

                  # Moving away from a new input line; save it in case
                  # we return.
                  if ($$hist_index == @$hist_list) {
                    $$input_hold = $$input;
                  }

                  # Move cursor to start of input.
                  if ($$cursor_input) {
                    $termcap->Tgoto( 'LE', 1, $$cursor_display, *STDOUT );
                  }

                  # Clear to end of line.
                  if (length $$input) {
                    if ($tc_has_ke) {
                      print $termcap->Tputs( 'kE', 1 );
                    }
                    else {
                      my $display_width = display_width($$input);
                      print ' ' x $display_width;
                      $termcap->Tgoto( 'LE', 1, $display_width, *STDOUT );
                    }
                  }

                  # Move the history cursor back, set the new input
                  # buffer, and show what the user's editing.  Set the
                  # cursor to the end of the new line.
                  my $normal;
                  print $normal =
                    normalize($$input = $hist_list->[--$$hist_index]);
                  $$cursor_input = length($$input);
                  $$cursor_display = length($normal);
                }
                else {
                  # At top of history list.
                  print $tc_bell;
                }
                next;
              }

              # Next in history.
              if ($key eq '^N' or $key eq $tck_down) {
                if ($$hist_index < @$hist_list) {

                  # Move cursor to start of input.
                  if ($$cursor_input) {
                    $termcap->Tgoto( 'LE', 1, $$cursor_display, *STDOUT );
                  }

                  # Clear to end of line.
                  if (length $$input) {
                    if ($tc_has_ke) {
                      print $termcap->Tputs( 'kE', 1 );
                    }
                    else {
                      my $display_width = display_width($$input);
                      print ' ' x $display_width;
                      $termcap->Tgoto( 'LE', 1, $display_width, *STDOUT );
                    }
                  }

                  my $normal;
                  if (++$$hist_index == @$hist_list) {
                    # Just past the end of the history.  Whatever was
                    # there when we left it.
                    print $normal = normalize($$input = $$input_hold);
                  }
                  else {
                    # There's something in the history list.  Make that
                    # the current line.
                    print $normal =
                      normalize($$input = $hist_list->[$$hist_index]);
                  }

                  $$cursor_input = length($$input);
                  $$cursor_display = length($normal);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # First in history.
              if ($key eq '^[<') {
                if ($$hist_index) {

                  # Moving away from a new input line; save it in case
                  # we return.
                  if ($$hist_index == @$hist_list) {
                    $$input_hold = $$input;
                  }

                  # Move cursor to start of input.
                  if ($$cursor_input) {
                    $termcap->Tgoto( 'LE', 1, $$cursor_display, *STDOUT );
                  }

                  # Clear to end of line.
                  if (length $$input) {
                    if ($tc_has_ke) {
                      print $termcap->Tputs( 'kE', 1 );
                    }
                    else {
                      my $display_width = display_width($$input);
                      print ' ' x $display_width;
                      $termcap->Tgoto( 'LE', 1, $display_width, *STDOUT );
                    }
                  }

                  # Move the history cursor back, set the new input
                  # buffer, and show what the user's editing.  Set the
                  # cursor to the end of the new line.
                  print my $normal =
                    normalize($$input = $hist_list->[$$hist_index = 0]);
                  $$cursor_input = length($$input);
                  $$cursor_display = length($normal);
                }
                else {
                  # At top of history list.
                  print $tc_bell;
                }
                next;
              }

              # Last in history.
              if ($key eq '^[>') {
                if ($$hist_index != @$hist_list - 1) {

                  # Moving away from a new input line; save it in case
                  # we return.
                  if ($$hist_index == @$hist_list) {
                    $$input_hold = $$input;
                  }

                  # Move cursor to start of input.
                  if ($$cursor_input) {
                    $termcap->Tgoto( 'LE', 1, $$cursor_display, *STDOUT );
                  }

                  # Clear to end of line.
                  if (length $$input) {
                    if ($tc_has_ke) {
                      print $termcap->Tputs( 'kE', 1 );
                    }
                    else {
                      my $display_width = display_width($$input);
                      print ' ' x $display_width;
                      $termcap->Tgoto( 'LE', 1, $display_width, *STDOUT );
                    }
                  }

                  # Move the edit line down to the last history line.
                  $$hist_index = @$hist_list - 1;
                  print my $normal =
                    normalize($$input = $hist_list->[$$hist_index]);
                  $$cursor_input = length($$input);
                  $$cursor_display = length($normal);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Capitalize from cursor on.  This needs uc($key).
              if (uc($key) eq '^[C') {

                # If there's text to capitalize.
                if (substr($$input, $$cursor_input) =~ /^(\s*)(\S+)/) {

                  # Track leading space, and uppercase word.
                  my $space = $1; $space = '' unless defined $space;
                  my $word  = ucfirst(lc($2));

                  # Replace text with the uppercase version.
                  substr( $$input,
                          $$cursor_input + length($space), length($word)
                        ) = $word;

                  # Display the new text; move the cursor after it.
                  print $space, normalize($word);
                  $$cursor_input += length($space . $word);
                  $$cursor_display += length($space) + display_width($word);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Uppercase from cursor on.  This needs uc($key).
              # Modelled after capitalize.
              if (uc($key) eq '^[U') {
                if (substr($$input, $$cursor_input) =~ /^(\s*)(\S+)/) {
                  my $space = $1; $space = '' unless defined $space;
                  my $word  = uc($2);
                  substr( $$input,
                          $$cursor_input + length($space), length($word)
                        ) = $word;
                  print $space, normalize($word);
                  $$cursor_input += length($space . $word);
                  $$cursor_display += length($space) + display_width($word);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Lowercase from cursor on.  This needs uc($key).
              # Modelled after capitalize.
              if (uc($key) eq '^[L') {
                if (substr($$input, $$cursor_input) =~ /^(\s*)(\S+)/) {
                  my $space = $1; $space = '' unless defined $space;
                  my $word  = lc($2);
                  substr( $$input,
                          $$cursor_input + length($space), length($word)
                        ) = $word;
                  print $space, normalize($word);
                  $$cursor_input += length($space . $word);
                  $$cursor_display += length($space) + display_width($word);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Forward one word.  This needs uc($key).  Modelled
              # vaguely after capitalize.
              if (uc($key) eq '^[F') {
                if (substr($$input, $$cursor_input) =~ /^(\s*\S+)/) {
                  $$cursor_input += length($1);
                  my $right = display_width($1);
                  $termcap->Tgoto( 'RI', 1, $right, *STDOUT );
                  $$cursor_display += $right;
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Delete a word forward.  This needs uc($key).
              if (uc($key) eq '^[D') {
                if ($$cursor_input < length($$input)) {
                  substr($$input, $$cursor_input) =~ s/^(\s*\S*\s*)//;
                  my $killed_width = display_width($1);

                  my $normal_remaining =
                    normalize(substr($$input, $$cursor_input));
                  print $normal_remaining;
                  my $normal_remaining_length = length($normal_remaining);

                  if ($tc_has_ke) {
                    print $termcap->Tputs( 'kE', 1 );
                  }
                  else {
                    print ' ' x $killed_width;
                    $normal_remaining_length += $killed_width;
                  }

                  $termcap->Tgoto( 'LE', 1, $normal_remaining_length, *STDOUT )
                    if $normal_remaining_length;
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Backward one word.  This needs uc($key).
              if (uc($key) eq '^[B') {
                if (substr($$input, 0, $$cursor_input) =~ /(\S+\s*)$/) {
                  $$cursor_input -= length($1);
                  my $kill_width = display_width($1);
                  $termcap->Tgoto( 'LE', 1, $kill_width, *STDOUT );
                  $$cursor_display -= $kill_width;
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Transpose words.  This needs uc($key).
              if (uc($key) eq '^[T') {
                my $cursor_sub_one = $$cursor_input - 1;
                if ( $$input =~
                     s/^(.{0,$cursor_sub_one})(?<!\S)(\S+)(\s+)(\S+)/$1$4$3$2/
                   ) {
                  $termcap->Tgoto( 'LE', 1,
                                   $$cursor_display - display_width($1),
                                   *STDOUT
                                 );
                  print normalize($4 . $3 . $2);
                  $$cursor_input = length($1 . $2 . $3 . $4);
                  $$cursor_display = display_width($1 . $2 . $3 . $4);
                }
                else {
                  print $tc_bell;
                }
                next;
              }

              # Toggle insert mode.
              if ($key eq $tck_insert) {
                $$insert_mode = !$$insert_mode;
                next;
              }
            }

            # C-q displays some stuff.
            if ($key eq '^Q') {
              my $left = display_width(substr($$input, $$cursor_input));
              print( "\x0D\x0A",
                     "cursor_input($$cursor_input) ",
                     "cursor_display($$cursor_display) ",
                     "term_columns($trk_cols)\x0D\x0A",
                     $$prompt, normalize($$input)
                   );
              $termcap->Tgoto( 'LE', 1, $left, *STDOUT ) if $left;
              next;
            }

            # The raw key is more than 1 character; this is a failed
            # function key or something.  Don't allow it to be
            # entered.
            if (length($raw_key) > 1) {
              print $tc_bell;
              next;
            }

            # This is after the meta key checks.  Meta keys that
            # aren't known will fall through here.  Add the keystroke
            # to the input buffer.

            if ($$cursor_input < length($$input)) {
              if ($$insert_mode) {
                # Insert.
                my $normal = normalize(substr($$input, $$cursor_input));
                substr($$input, $$cursor_input, 0) = $raw_key;
                print $key, $normal;
                $$cursor_input += length($raw_key);
                $$cursor_display += length($key);
                $termcap->Tgoto( 'LE', 1, length($normal), *STDOUT );
              }
              else {
                # Overstrike.
                my $replaced_width =
                  display_width
                    ( substr($$input, $$cursor_input, length($raw_key))
                    );
                substr($$input, $$cursor_input, length($raw_key)) = $raw_key;

                print $key;
                $$cursor_input += length($raw_key);
                $$cursor_display += length($key);

                # Expand or shrink the display if unequal replacement.
                if (length($key) != $replaced_width) {
                  my $rest = normalize(substr($$input, $$cursor_input));
                  # Erase trailing screen cruft if it's shorter.
                  if (length($key) < $replaced_width) {
                    $rest .= ' ' x ($replaced_width - length($key));
                  }
                  print $rest;
                  $termcap->Tgoto( 'LE', 1, length($rest), *STDOUT );
                }
              }
            }
            else {
              # Append.
              print $key;
              $$input .= $raw_key;
              $$cursor_input += length($raw_key);
              $$cursor_display += length($key);
            }
          }
        }
      );

    # Now select on it.
    $poe_kernel->select_read( *STDIN, $self->[SELF_STATE_READ] );
  }

  # Otherwise we're undefining it.
  else {
    $poe_kernel->select_read( *STDIN );
  }

}

# Send a prompt; get a line.
sub get {
  my ($self, $prompt) = @_;

  # Already reading a line here, people.  Sheesh!
  return if $self->[SELF_READING_LINE];

  # Set up for the read.
  $self->[SELF_READING_LINE]   = 1;
  $self->[SELF_PROMPT]         = $prompt;
  $self->[SELF_INPUT]          = '';
  $self->[SELF_CURSOR_INPUT]   = 0;
  $self->[SELF_CURSOR_DISPLAY] = 0;
  $self->[SELF_HIST_INDEX]     = @{$self->[SELF_HIST_LIST]};
  $self->[SELF_INSERT_MODE]    = 1;

  # Watch the filehandle.
  $poe_kernel->select( *STDIN, $self->[SELF_STATE_READ] );

  print $prompt;
}

# Helper to wipe the current input line.
sub _wipe_input_line {
  my $self = shift;

  # Clear the current prompt and input, and home the cursor.
  print $termcap->Tgoto( 'LE', 1,
                         ( $self->[SELF_CURSOR_DISPLAY] +
                           length($self->[SELF_PROMPT])
                         )
                       );
  if ($tc_has_ke) {
    print $termcap->Tputs( 'kE', 1 );
  }
  else {
    my $wipe_length =
      ( length($self->[SELF_PROMPT]) +
        display_width($self->[SELF_INPUT])
      );
    print( (' ' x $wipe_length), $termcap->Tgoto( 'LE', 1, $wipe_length) );
  }
}

# Helper to flush any buffered output.
sub _flush_output_buffer {
  my $self = shift;

  # Flush anything buffered.
  if (@{$self->[SELF_PUT_BUFFER]}) {
    print @{$self->[SELF_PUT_BUFFER]};

    # Do not change the interior listref, or the event handlers will
    # become confused.
    @{$self->[SELF_PUT_BUFFER]} = ( );
  }
}

# Set up the prompt and input line like nothing happened.
sub _repaint_input_line {
  my $self = shift;

  print( $self->[SELF_PROMPT], normalize($self->[SELF_INPUT]) );
  if ($self->[SELF_CURSOR_INPUT] != length($self->[SELF_INPUT])) {
    $termcap->Tgoto( 'LE', 1,
                     ( display_width($self->[SELF_INPUT]) -
                       $self->[SELF_CURSOR_DISPLAY]
                     ),
                     *STDOUT
                   );
  }
}

# Write a line on the terminal.
sub put {
  my $self = shift;
  my @lines = map { $_ . "\x0D\x0A" } @_;

  # Write stuff immediately under certain conditions: (1) The wheel is
  # in immediate mode.  (2) The wheel currently isn't reading a line.
  # (3) The wheel is in idle mode, and there.

  if ( $self->[SELF_PUT_MODE] eq 'immediate' or
       !$self->[SELF_READING_LINE] or
       ( $self->[SELF_PUT_MODE] eq 'idle' and !$self->[SELF_HAS_TIMER] )
     ) {

    #unshift( @lines,
    #         "putmode($self->[SELF_PUT_MODE]) " .
    #         "reading($self->[SELF_READING_LINE]) " .
    #         "timer($self->[SELF_HAS_TIMER]) "
    #       );

    $self->_wipe_input_line();
    $self->_flush_output_buffer();

    # Print the new stuff.
    print @lines;

    # Only repaint the input if we're reading a line.
    $self->_repaint_input_line() if $self->[SELF_READING_LINE];

    return;
  }

  # Otherwise buffer stuff.
  push @{$self->[SELF_PUT_BUFFER]}, @lines;

  # Set a timer, if timed.
  if ( $self->[SELF_PUT_MODE] eq 'idle' and !$self->[SELF_HAS_TIMER] ) {
    $poe_kernel->delay( $self->[SELF_STATE_IDLE], $self->[SELF_IDLE_TIME] );
    $self->[SELF_HAS_TIMER] = 1;
  }
}


# Add things to the edit history.
sub addhistory {
  my $self = shift;
  push @{$self->[SELF_HIST_LIST]}, @_;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ReadLine - prompted terminal input with basic editing keys

=head1 SYNOPSIS

  # Create the wheel.
  $heap->{wheel} = POE::Wheel::ReadLine->new( InputEvent => got_input );

  # Trigger the wheel to read a line of input.
  $wheel->get( 'Prompt: ' );

  # Add a line to the wheel's input history.
  $wheel->addhistory( $input );

  # Input handler.  If $input is defined, then it contains a line of
  # input.  Otherwise $exception contains a word describing some kind
  # of user exception.  Currently these are 'interrupt' and 'cancel'.
  sub got_input_handler {
    my ($heap, $input, $exception) = @_[HEAP, ARG0, ARG1];
    if (defined $input) {
      $heap->{wheel}->addhistory($input);
      print "\tGot: $input\n";
      $heap->{wheel}->get('Prompt: '); # get another line
    }
    else {
      print "\tException: $exception\n";
    }
  }

=head1 DESCRIPTION

ReadLine performs non-blocking, event-driven console input, using
Term::Cap to interact with the terminal display and Term::ReadKey to
interact with its keyboard.

ReadLine handles a number of common input editing keys; it also
provides an input history list.  It's not, however, a fully featured
Term::ReadLine replacement, although it probably will approach one
over time.

=head1 EDITING KEYS

These are the editing keystrokes that ReadLine uses to facilitate text
editing.  Some of them, such as Home, End, Insert, and Delete, may not
work on every terminal.

Keystrokes are in the form X-y or X-X-z.  X designates a modifier,
which can be C for "control" or M for "meta".  The only meta key
currently supported is the Escape key, chr(27).

=over 2

=item C-a (Control-A)

=item Home

Moves the cursor to the beginning of the line.

=item C-b

=item Left arrow

Moves the cursor one character back towards the beginning of the line.

=item C-c

Interrupt the program.  This stops editing the current line and emits
an InputEvent event.  The event's C<ARG0> parameter is undefined, and
its C<ARG1> parameter contains the word "interrupt".

=item C-d

=item Delete

Delete the character under the cursor.

=item C-e

=item End

Move the cursor to the end of the input line.

=item C-f

=item Right arrow

Move the cursor one character forward.  This moves it closer to the
end of the line.

=item C-g

Cancle text entry.  This stops editing the current line and emits an
InputEvent event.  The event's C<ARG0> parameter is undefined, and its
C<ARG1> parameter contains the word "cancel".

=item C-h

=item Backspace

Delete the character before the cursor.

=item C-j

=item Enter / Return

C-j is the newline keystroke on Unix-y systems.  It ends text entry,
firing an InputEvent with C<ARG0> containing the entered text (without
the terminating newline).  C<ARG1> is undefined because there is no
exception.

=item C-k

Kill to end of line.  Deletes all text from the cursor position to the
end of the line.

=item C-l

Clear the screen and repaint the prompt and current input line.

=item C-m

=item Enter / Return

C-m is the newline keystroke on Unix-y systems.  It ends text entry,
firing an InputEvent with C<ARG0> containing the entered text (without
the terminating newline).  C<ARG1> is undefined because there is no
exception.

=item C-n

=item Down arrow

Scroll forward through the line history list.  This replaces the
current input line with the one entered after it.

=item C-p

=item Up arrow

Scroll back through the line history list.  This replaces the current
input line with the one entered before it.

=item C-t

Transpose the character before the cursor with the one under it.  Tihs
si gerat fro fxiing cmoon tyopes.

=item C-u

Discard the entire line.  Throws away everything and starts anew.

=item C-w

=item M-C-h (Escape Control-h)

Word rubout.  Discards from just before the cursor to the beginning of
the word immediately before it.

=item M-< (Escape-<)

First history line.  Replaces the current input line with the first
one in the history list.

=item M->

Last history line.  Replaces the current input line with the last one
in the history list.  Pressing C-n or the down arrow key after this
will recall whatever was being entered before the user began looking
through the history list.

=item M-b

Move the cursor backwards one word.  The cursor's final resting place
is at the start of the word on or before the cursor's original
location.

=item M-c

Capitalize the first letter on or after the cursor, and lowercase
subsequent characters in the word.  Some examples follow.  The caret
marks the character under the cursor before M-c is pressed.

  capITALize  tHiS   ... becomes ...   Capitalize  tHiS
  ^                                              ^

  capITALize  tHiS   ... becomes ...   capITALiZe  tHiS
          ^                                      ^

  capITALize  tHiS   ... becomes ...   capITALize  This
            ^                                          ^

=item M-d

Forward word delete.  Deletes from the cursor position to the end of
the first word on or after the cursor.  The text that is deleted is
the same as the text that M-c, M-l, and M-u change.  It also coincides
with the text that M-f skip.

=item M-f

Move the cursor forward one word.  The cursor actually moves to the
end of the first word under or after the cursor.  This motion is the
same for M-c, M-l, and M-u.

=item M-l

Uppercases the entire word beginning on or after the cursor position.
Here are some examples; the caret points to the character under the
cursor before and after M-u are pressed.

  LOWERCASE  THIS   ... becomes ...   lowercase  THIS
  ^                                            ^

  LOWERCASE  THIS   ... becomes ...   LOWERcase  THIS
       ^                                       ^

  LOWERCASE  THIS   ... becomes ...   LOWERCASE  this
           ^                                         ^

=item M-t

Transpose words.

If the cursor is within the last word in the input line, then that
word is transposed with the one before it.

  one  two  three   ... becomes ...   one  three  two
               ^                                     ^

If the cursor is within any other word in the input line, then that
word is transposed with the next one.

  one  two  three   ... becomes ...   two  one  three
   ^                                          ^

If the cursor is in the whitespace between words, then the words on
either side of the whitespace are transposed.

  one  two  three   ... becomes ...   two  one  three
      ^                                       ^

=item M-u

Uppercases the entire word beginning on or after the cursor position.
Here are some examples; the caret points to the character under the
cursor before and after M-u are pressed.

  uppercase  this   ... becomes ...   UPPERCASE  this
  ^                                            ^

  uppercase  this   ... becomes ...   upperCASE  this
       ^                                       ^

  uppercase  this   ... becomes ...   uppercase  THIS
           ^                                         ^

=back

=head1 PUBLIC METHODS

=over 2

=item get PROMPT

Provide a prompt and enable input.  The wheel will display the prompt
and begin paying attention to the console keyboard after this method
is called.  Once a line or an exception is returned, the wheel will
resume its quiescent state wherein it ignores keystrokes.

The quiet period between input events gives a program the opportunity
to change the prompt or process lines before the next one arrives.

=item addhistory LIST_OF_LINES

=back

=head1 EVENTS AND PARAMETERS

=over 2

=item InputEvent

InputEvent contains the name of the event that will be fired upon
successful (or unsuccessful) terminal input.  Every InputEvent handler
receives two additional parameters, only one of which is ever defined
at a time.  C<ARG0> contains the input line, if one was present.  If
C<ARG0> is not defined, then C<ARG1> contains a word describing a
user-generated exception:

The 'interrupt' exception means a user pressed C-c (^C) to interrupt
the program.  It's up to the input event's handler to decide what to
do next.

The 'cancel' exception means a user pressed C-g (^G) to cancel a line
of input.

=item PutMode

PutMode specifies how the wheel will display text when its C<put()>
method is called.

C<put()> displays text immediately when the user isn't being prompted
for input.  It will also pre-empt the user to display text right away
when PutMode is "immediate".

When PutMode is "after", all C<put()> text is held until after the
user enters or cancels (See C-g) her input.

PutMode can also be "idle".  In this mode, text is displayed right
away if the keyboard has been idle for a certian period (see the
IdleTime parameter).  Otherwise it's held as in "after" mode until
input is completed or canceled, or until the keyboard becomes idle for
at least IdleTime seconds.  This is ReadLine's default mode.

=item IdleTime

IdleTime specifies how long the keyboard must be idle before C<put()>
becomes immediate or buffered text is flushed to the display.  It is
only meaningful when InputMode is "idle".  IdleTime defaults to two
seconds.

=back

=head1 SEE ALSO

POE::Wheel.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

=over 2

=item Non-optimal code

Dissociating the input and display cursors introduced a lot of code.
Much of this code was thrown in hastily, and things can probably be
done with less work.  To do: Apply some thought to what's already been
done.

The screen should update as quickly as possible, especially on slow
systems.  Do little or no calculation during displaying; either put it
all before or after the display.  Do it consistently for each handled
keystroke, so that certain pairs of editing commands don't have extra
perceived latency.

=item Unimplemented features

Input editing is not kept on one line.  If it wraps, and a terminal
cannot wrap back through a line division, the cursor will become lost.
This bites, and it's the next against the wall in my bug hunting.

Unicode, or at least European code pages.  I feel real bad about
throwing away native representation of all the 8th-bit-set characters.
I also have no idea how to do this, and I don't have a system to test
this.  Patches are recommended.

SIGWINCH tends to kill Perl quickly, and POE ignores it.  Resizing a
terminal window has no effect.  Making this useful will require signal
polling, perhaps in the wheel itself (either as a timer loop, a
keystroke, or per every N keystrokes) or in POE::Kernel.  I'm not sure
which yet.

Tab completion:

  C-i     cycle through completions
  C-x *   insert possible completions
  C-x ?   list possible completions
  M-?     list possible completions

Input options:

  C-q     quoted insert (unprocessed keystroke)
  M-Tab   insert literal tab
  C-_     undo

History searching:

  C-s     search history
  C-r     reverse search history
  C-v     forward search history

=back

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
