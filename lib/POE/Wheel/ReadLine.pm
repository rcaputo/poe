# $Id$

package POE::Wheel::ReadLine;

use strict;
use bytes; # don't assume UTF while reading bizarre key sequences

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

use Carp;
use Symbol qw(gensym);
use POE qw(Wheel);
use POSIX;

# Things we'll need to interact with the terminal.
use Term::Cap;
use Term::ReadKey;

my $initialised = 0;
my $termcap;         # Termcap entry.
my $tc_bell;         # How to ring the terminal.
my $tc_visual_bell;  # How to ring the terminal.
my $tc_has_ce;       # Termcap can clear to end of line.

# Screen extent.
my ($trk_rows, $trk_cols);

# Private STDIN and STDOUT.
my $stdin  = gensym();
open($stdin, "<&0") or die "Can't open private STDIN";

my $stdout = gensym;
open($stdout, ">&1") or die "Can't open private STDOUT";

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
sub SELF_UNIQUE_ID      () { 17 }
sub SELF_KEYMAP         () { 18 }
sub SELF_OPTIONS        () { 19 }
sub SELF_APP            () { 20 }
sub SELF_ALL_KEYMAPS    () { 21 }
sub SELF_PENDING        () { 22 }
sub SELF_COUNT          () { 23 }
sub SELF_MARK           () { 24 }
sub SELF_MARKLIST       () { 25 }
sub SELF_KILL_RING      () { 26 }
sub SELF_LAST           () { 27 }
sub SELF_PENDING_FN     () { 28 }
sub SELF_SOURCE         () { 29 }
sub SELF_SEARCH         () { 30 }
sub SELF_SEARCH_PROMPT  () { 31 }
sub SELF_SEARCH_MAP     () { 32 }
sub SELF_PREV_PROMPT    () { 33 }
sub SELF_SEARCH_DIR     () { 34 }
sub SELF_SEARCH_KEY     () { 35 }
sub SELF_UNDO           () { 36 }

sub CRIMSON_SCOPE_HACK ($) { 0 }

#------------------------------------------------------------------------------

# Build a hash of input characters and their "normalized" display
# versions.  ISO Latin-1 characters (8th bit set "ASCII") are
# mishandled.  European users, please forgive me.  If there's a good
# way to handle this-- perhaps this is an interesting use for
# Unicode-- please let me know.

my (%normalized_character, @normalized_extra_width);

#------------------------------------------------------------------------------
# Gather information about the user's terminal.  This just keeps
# getting uglier.

my $ospeed = undef;
my $termios = undef;
my $term = undef;
my $termios = undef;
my $tc_left = undef;
my $trk_cols = undef;
my $trk_rows = undef;

sub curs_left {
  my $amount = shift;

  if ($tc_left eq "LE") {
    $termcap->Tgoto($tc_left, 1, $amount, $stdout);
    return;
  }

  for (1..$amount) {
    $termcap->Tgoto($tc_left, 1, 1, $stdout);
  }
}


our $defuns = {
"abort"                                  => \&rl_abort,
"accept-line"                            => \&rl_accept_line,
"backward-char"                          => \&rl_backward_char,
"backward-delete-char"                   => \&rl_backward_delete_char,
"backward-kill-line"                     => \&rl_unix_line_discard, # reuse emacs
"backward-kill-word"                     => \&rl_backward_kill_word,
"backward-word"                          => \&rl_backward_word,
"beginning-of-history"                   => \&rl_beginning_of_history,
"beginning-of-line"                      => \&rl_beginning_of_line,
"capitalize-word"                        => \&rl_capitalize_word,
"character-search"                       => \&rl_character_search,
"character-search-backward"              => \&rl_character_search_backward,
"clear-screen"                           => \&rl_clear_screen,
"complete"                               => \&rl_complete,
"copy-region-as-kill"                    => \&rl_copy_region_as_kill,
"delete-char"                            => \&rl_delete_char,
"delete-horizontal-space"                => \&rl_delete_horizontal_space,
"digit-argument"                         => \&rl_digit_argument,
"ding"                                   => \&rl_ding,
"downcase-word"                          => \&rl_downcase_word,
"dump-key"                               => \&rl_dump_key,
"dump-macros"                            => \&rl_dump_macros,
"dump-variables"                         => \&rl_dump_variables,
"emacs-editing-mode"                     => \&rl_emacs_editing_mode,
"end-of-history"                         => \&rl_end_of_history,
"end-of-line"                            => \&rl_end_of_line,
"forward-char"                           => \&rl_forward_char,
"forward-search-history"                 => \&rl_forward_search_history,
"forward-word"                           => \&rl_forward_word,
"insert-comment"                         => \&rl_insert_comment,
"insert-completions"                     => \&rl_insert_completions,
"insert-macro"                           => \&rl_insert_macro,
"interrupt"                              => \&rl_interrupt,
"isearch-again"                          => \&rl_isearch_again,
"kill-line"                              => \&rl_kill_line,
"kill-region"                            => \&rl_kill_region,
"kill-whole-line"                        => \&rl_kill_whole_line,
"kill-word"                              => \&rl_kill_word,
"next-history"                           => \&rl_next_history,
"non-incremental-forward-search-history" => \&rl_non_incremental_forward_search_history,
"non-incremental-reverse-search-history" => \&rl_non_incremental_reverse_search_history,
"overwrite-mode"                         => \&rl_overwrite_mode,
"poe-wheel-debug"                        => \&rl_poe_wheel_debug,
"possible-completions"                   => \&rl_possible_completions,
"previous-history"                       => \&rl_previous_history,
"quoted-insert"                          => \&rl_quoted_insert,
"re-read-init-file"                      => \&rl_re_read_init_file,
"redraw-current-line"                    => \&rl_redraw_current_line,
"reverse-search-history"                 => \&rl_reverse_search_history,
"revert-line"                            => \&rl_revert_line,
"search-abort"                           => \&rl_search_abort,
"search-finish"                          => \&rl_search_finish,
"search-key"                             => \&rl_search_key,
"self-insert"                            => \&rl_self_insert,
"set-keymap"                             => \&rl_set_keymap,
"set-mark"                               => \&rl_set_mark,
"tab-insert"                             => \&rl_ding, # UNIMPLEMENTED
"tilde-expand"                           => \&rl_tilde_expand,
"transpose-chars"                        => \&rl_transpose_chars,
"transpose-words"                        => \&rl_transpose_words,
"undo"                                   => \&rl_undo,
"unix-line-discard"                      => \&rl_unix_line_discard,
"unix-word-rubout"                       => \&rl_unix_word_rubout,
"upcase-word"                            => \&rl_upcase_word,
"vi-append-eol"                          => \&rl_vi_append_eol,
"vi-append-mode"                         => \&rl_vi_append_mode,
"vi-arg-digit"                           => \&rl_vi_arg_digit,
"vi-change-case"                         => \&rl_vi_change_case,
"vi-change-char"                         => \&rl_vi_change_char,
"vi-change-to"                           => \&rl_vi_change_to,
"vi-char-search"                         => \&rl_vi_char_search,
"vi-column"                              => \&rl_vi_column,
"vi-complete"                            => \&rl_vi_cmplete,
"vi-delete"                              => \&rl_vi_delete,
"vi-delete-to"                           => \&rl_vi_delete_to,
"vi-editing-mode"                        => \&rl_vi_editing_mode,
"vi-end-spec"                            => \&rl_vi_end_spec,
"vi-end-word"                            => \&rl_vi_end_word,
"vi-eof-maybe"                           => \&rl_vi_eof_maybe,
"vi-fetch-history"                       => \&rl_beginning_of_history, # re-use emacs version
"vi-first-print"                         => \&rl_vi_first_print,
"vi-goto-mark"                           => \&rl_vi_goto_mark,
"vi-insert-beg"                          => \&rl_vi_insert_beg,
"vi-insertion-mode"                      => \&rl_vi_insertion_mode,
"vi-match"                               => \&rl_vi_match,
"vi-movement-mode"                       => \&rl_vi_movement_mode,
"vi-next-word"                           => \&rl_vi_next_word,
"vi-prev-word"                           => \&rl_vi_prev_word,
"vi-put"                                 => \&rl_vi_put,
"vi-redo"                                => \&rl_vi_redo,
"vi-replace"                             => \&rl_vi_replace,
"vi-search"                              => \&rl_vi_search,
"vi-search-accept"                       => \&rl_vi_search_accept,
"vi-search-again"                        => \&rl_vi_search_again,
"vi-search-key"                          => \&rl_vi_search_key,
"vi-set-mark"                            => \&rl_vi_set_mark,
"vi-spec-beginning-of-line"              => \&rl_vi_spec_beginning_of_line,
"vi-spec-end-of-line"                    => \&rl_vi_spec_end_of_line,
"vi-spec-first-print"                    => \&rl_vi_spec_first_print,
"vi-spec-forward-char"                   => \&rl_vi_spec_forward_char,
"vi-spec-mark"                           => \&rl_vi_spec_mark,
"vi-spec-word"                           => \&rl_vi_spec_word,
"vi-subst"                               => \&rl_vi_subst,
"vi-tilde-expand"                        => \&rl_vi_tilde_expand,
"vi-undo"                                => \&rl_undo, # re-use emacs version
"vi-yank-arg"                            => \&rl_vi_yank_arg,
"vi-yank-to"                             => \&rl_vi_yank_to,
"yank"                                   => \&rl_yank,
"yank-last-arg"                          => \&rl_yank_last_arg,
"yank-nth-arg"                           => \&rl_yank_nth_arg,
"yank-pop"                               => \&rl_yank_pop,
};

# what functions are for counting
my @fns_counting = (
		    'rl_vi_arg_digit',
		    'rl_digit_argument',
		    'rl_universal-argument',
		   );

# what functions are purely for movement...
my @fns_movement = (
		    'rl_beginning_of_line',
		    'rl_backward_char',
		    'rl_forward_char',
		    'rl_backward_word',
		    'rl_forward_word',
		    'rl_end_of_line',
		    'rl_character_search',
		    'rl_character_search_backward',
		    'rl_vi_prev_word',
		    'rl_vi_next_word',
		    'rl_vi_goto_mark',
		    'rl_vi_end_word',
		    'rl_vi_column',
		    'rl_vi_first_print',
		    'rl_vi_char_search',
		    'rl_vi_spec_char_search',
		    'rl_vi_spec_end_of_line',
		    'rl_vi_spec_beginning_of_line',
		    'rl_vi_spec_first_print',
		    'rl_vi_spec_word',
		    'rl_vi_spec_mark',
		   );

# the list of functions that we don't want to record for
# later redo usage in vi mode.
my @fns_anon = (
		'rl_vi_redo',
		@fns_counting,
		@fns_movement,
	       );


my $defaults_inputrc = <<'INPUTRC';
set comment-begin #
INPUTRC

my $emacs_inputrc = <<'INPUTRC';
C-a: beginning-of-line
C-b: backward-char
C-c: interrupt
C-d: delete-char
C-e: end-of-line
C-f: forward-char
C-g: abort
C-h: backward-delete-char
C-i: complete
C-j: accept-line
C-k: kill-line
C-l: clear-screen
C-m: accept-line
C-n: next-history
C-p: previous-history
C-q: poe-wheel-debug
C-r: reverse-search-history
C-s: forward-search-history
C-t: transpose-chars
C-u: unix-line-discard
C-v: quoted-insert
C-w: unix-word-rubout
C-y: yank
C-]: character-search
C-_: undo
del: backward-delete-char

M-C-g: abort
M-C-h: backward-kill-word
M-C-i: tab-insert
M-C-j: vi-editing-mode
M-C-r: revert-line
M-C-y: yank-nth-arg
M-C-[: complete
M-C-]: character-search-backward
M-space: set-mark
M-#: insert-comment
M-&: tilde-expand
M-*: insert-completions
M--: digit-argument
M-.: yank-last-arg
M-0: digit-argument
M-1: digit-argument
M-2: digit-argument
M-3: digit-argument
M-4: digit-argument
M-5: digit-argument
M-6: digit-argument
M-7: digit-argument
M-8: digit-argument
M-9: digit-argument
M-<: beginning-of-history
M->: end-of-history
M-?: possible-completions

M-b: backward-word
M-c: capitalize-word
M-d: kill-word
M-f: forward-word
M-l: downcase-word
M-n: non-incremental-forward-search-history
M-p: non-incremental-reverse-search-history
M-r: revert-line
M-t: transpose-words
M-u: upcase-word
M-y: yank-pop
M-\: delete-horizontal-space
M-~: tilde-expand
M-del: backward-kill-word
M-_: yank-last-arg

C-xC-r: re-read-init-file
C-xC-g: abort
C-xDel: backward-kill-line
C-xm: dump-macros
C-xv: dump-variables
C-xk: dump-key

home: beginning-of-line
end: end-of-line
ins: overwrite-mode
del: delete-char
left: backward-char
right: forward-char
up: previous-history
down: next-history
bs: backward-delete-char
INPUTRC

my $vi_inputrc = <<'INPUTRC';

# VI uses two keymaps, depending on which mode we're in.
set keymap vi-insert

C-d: vi-eof-maybe
C-h: backward-delete-char
C-i: complete
C-j: accept-line
C-m: accept-line
C-r: reverse-search-history
C-s: forward-search-history
C-t: transpose-chars
C-u: unix-line-discard
C-v: quoted-insert
C-w: unix-word-rubout
C-y: yank
C-[: vi-movement-mode
C-_: undo
C-?: backward-delete-char

set keymap vi-command
C-d: vi-eof-maybe
C-e: emacs-editing-mode
C-g: abort
C-h: backward-char
C-j: accept-line
C-k: kill-line
C-l: clear-screen
C-m: accept-line
C-n: next-history
C-p: previous-history
C-q: quoted-insert
C-r: reverse-search-history
C-s: forward-search-history
C-t: transpose-chars
C-u: unix-line-discard
C-v: quoted-insert
C-w: unix-word-rubout
C-y: yank
C-_: vi-undo
" ": forward-char
"#": insert-comment
"$": end-of-line
"%": vi-match
"&": vi-tilde-expand
"*": vi-complete
"+": next-history
",": vi-char-search
"-": previous-history
".": vi-redo
"/": vi-search
"0": vi-arg-digit
"1": vi-arg-digit
"2": vi-arg-digit
"3": vi-arg-digit
"4": vi-arg-digit
"5": vi-arg-digit
"6": vi-arg-digit
"7": vi-arg-digit
"8": vi-arg-digit
"9": vi-arg-digit
";": vi-char-search
"=": vi-complete
"?": vi-search
A: vi-append-eol
B: vi-prev-word
C: vi-change-to
D: vi-delete-to
E: vi-end-word
F: vi-char-search
G: vi-fetch-history
I: vi-insert-beg
N: vi-search-again
P: vi-put
R: vi-replace
S: vi-subst
T: vi-char-search
U: revert-line
W: vi-next-word
X: backward-delete-char
Y: vi-yank-to
"\": vi-complete
"^": vi-first-print
"_": vi-yank-arg
"`": vi-goto-mark
a: vi-append-mode
b: backward-word
c: vi-change-to
d: vi-delete-to
e: vi-end-word
h: backward-char
i: vi-insertion-mode
j: next-history
k: previous-history
l: forward-char
m: vi-set-mark
n: vi-search-again
p: vi-put
r: vi-change-char
s: vi-subst
t: vi-char-search
w: vi-next-word
x: vi-delete
y: vi-yank-to
"|": vi-column
"~": vi-change-case

set keymap vi-specification
"^": vi-spec-first-print
"`": vi-spec-mark
"$": vi-spec-end-of-line
"0": vi-spec-beginning-of-line
"1": vi-arg-digit
"2": vi-arg-digit
"3": vi-arg-digit
"4": vi-arg-digit
"5": vi-arg-digit
"6": vi-arg-digit
"7": vi-arg-digit
"8": vi-arg-digit
"9": vi-arg-digit
w: vi-spec-word
t: vi-spec-forward-char

INPUTRC

my $search_inputrc = <<'INPUTRC';
set keymap isearch
C-r: isearch-again
C-s: isearch-again

set keymap vi-search
C-j: vi-search-accept
C-m: vi-search-accept
INPUTRC

#------------------------------------------------------------------------------
# Helper functions.

sub vislength {
    return 0 unless $_[0];
    my $len = length($_[0]);
    while ($_[0] =~ m{(\\\[.*?\\\])}g) {
	$len -= length($1);
    }
    return $len;
}

# Wipe the current input line.
sub wipe_input_line {
    my ($self) = shift;

    # Clear the current prompt and input, and home the cursor.
    curs_left( $self->[SELF_CURSOR_DISPLAY] + vislength($self->[SELF_PROMPT]));

    if ( $tc_has_ce ) {
	print $stdout $termcap->Tputs( 'ce', 1 );
    } else {
	my $wlen = vislength($self->[SELF_PROMPT]) + display_width($self->[SELF_INPUT]);
	print $stdout ( ' ' x $wlen);
	curs_left($wlen);
    }
}

# Helper to flush any buffered output.  
sub flush_output_buffer {
    my ($self) = shift;

    # Flush anything buffered.
    if ( @{ $self->[SELF_PUT_BUFFER] } ) {
        print $stdout @{ $self->[SELF_PUT_BUFFER] };

        # Do not change the interior listref, or the event handlers will
        # become confused.
        @{ $self->[SELF_PUT_BUFFER] } = ();
    }
}

# Set up the prompt and input line like nothing happened.  
sub repaint_input_line {
    my ($self) = shift;
    my $sp = $self->[SELF_PROMPT];
    $sp =~ s{\\[\[\]]}{}g;
    print $stdout $sp, normalize($self->[SELF_INPUT]);

    if ( $self->[SELF_CURSOR_INPUT] != length( $self->[SELF_INPUT]) ) {
	curs_left( display_width($self->[SELF_INPUT]) - $self->[SELF_CURSOR_DISPLAY] );
    }
}

sub clear_to_end {
    my ($self) = @_;
    if (length $self->[SELF_INPUT]) {
	if ($tc_has_ce) {
	    print $stdout $termcap->Tputs( 'ce', 1 );
	} else {
	    my $display_width = display_width($self->[SELF_INPUT]);
	    print $stdout ' ' x $display_width;
	    curs_left($display_width);
	}
    }
}

sub delete_chars {
    my ($self, $from, $howmany) = @_;
    # sanitize input
    if ($howmany < 0) {
	$from -= $howmany;
	$howmany = -$howmany;
	if ($from < 0) {
	    $howmany -= $from;
	    $from = 0;
	}
    }

    my $old = substr($self->[SELF_INPUT], $from, $howmany);
    my $killed_width = display_width($old);
    substr($self->[SELF_INPUT], $from, $howmany) = '';
    if ($self->[SELF_CURSOR_INPUT] > $from) {
	my $newdisp = length(normalize(substr($self->[SELF_INPUT], 0, $from)));
	curs_left($self->[SELF_CURSOR_DISPLAY] - $newdisp);
	$self->[SELF_CURSOR_INPUT] = $from;
	$self->[SELF_CURSOR_DISPLAY] = $newdisp;
    }

    my $normal_remaining = normalize(substr($self->[SELF_INPUT], $from));
    print $stdout $normal_remaining;
    my $normal_remaining_length = length($normal_remaining);

    if ($tc_has_ce) {
	print $stdout $termcap->Tputs( 'ce', 1 );
    } else {
	print $stdout ' ' x $killed_width;
	$normal_remaining_length += $killed_width;
    }

    curs_left($normal_remaining_length)
      if $normal_remaining_length;

    return $old;
}

sub search {
    my ($self, $rebuild) = @_;
    if ($rebuild) {
	$self->wipe_input_line;
	$self->build_search_prompt;
    }
    # find in history....
    my $found = 0;
    for (my $i = $self->[SELF_HIST_INDEX]; 
	 $i < scalar @{$self->[SELF_HIST_LIST]} && $i >= 0; 
	 $i += $self->[SELF_SEARCH_DIR]) {
	
	if ($self->[SELF_HIST_LIST]->[$i] =~ /$self->[SELF_SEARCH]/) {
	    $self->[SELF_HIST_INDEX] = $i;
	    $self->[SELF_INPUT] = $self->[SELF_HIST_LIST]->[$i];
	    $self->[SELF_CURSOR_INPUT] = 0;
	    $self->[SELF_CURSOR_DISPLAY] = 0;
	    $self->[SELF_UNDO] = [ $self->[SELF_INPUT], 0, 0 ]; # reset undo info
	    $found++;
	    last;
	}
    }
    $self->rl_ding unless $found;
    $self->repaint_input_line;
}

# Return a normalized version of a string.  This includes destroying
# 8th-bit-set characters, turning them into strange multi-byte
# sequences.  Apologies to everyone; please let me know of a portable
# way to deal with this.
sub normalize {
  local $_ = shift;
  s/([^ -~])/$normalized_character{$1}/g;
  return $_;
}

sub readable_key {
    my ($raw_key) = @_;
    my @text = ();
    foreach my $l (split(//, $raw_key)) {
	if (ord($l) == 0x1B) {
	    push(@text, 'Meta-');
	} elsif (ord($l) < 32) {
	    push(@text, 'Control-' . chr(ord($l)+64));
	} elsif (ord($l) > 128) {
	    my $l = ord($l)-128;
	    if ($l < 32) {
		$l = "Control-" . chr(ord($l)+64);
	    }
	    push(@text, 'Meta-' . chr($l));
	} else {
	    push(@text, $l);
	}
    }
    return join("", @text);
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

sub build_search_prompt {
    my ($self) = @_;
    $self->[SELF_PROMPT] = $self->[SELF_SEARCH_PROMPT];
    $self->[SELF_PROMPT] =~ s{%s}{$self->[SELF_SEARCH]};
}

sub global_init {
    return if $initialised;

    # Some platforms don't define this constant.
    unless (defined \&POSIX::B38400) {
	eval "sub POSIX::B38400 () { 0 }";
    }

    # Get the terminal speed for Term::Cap.
    $ospeed = POSIX::B38400();
    eval {
	$termios = POSIX::Termios->new();
	$termios->getattr();
	$ospeed = $termios->getospeed() || POSIX::B38400();
    };

    # Get the current terminal's capabilities.
    $term = $ENV{TERM} || 'vt100';
    $termcap = Term::Cap->Tgetent( { TERM => $term, OSPEED => $ospeed } );
    die "could not find termcap entry for ``$term'': $!" unless defined $termcap;

    # Require certain capabilites.
    $termcap->Trequire( qw( cl ku kd kl kr) );

    # Cursor movement.
    $tc_left = "LE";
    eval { $termcap->Trequire($tc_left) };
    if ($@) {
	$tc_left = "le";
	eval { $termcap->Trequire($tc_left) };
	if ($@) {
	    # try out to see if we have a better terminfo defun.
	    # it may well not work (hence eval the lot), but it's worth a shot
	    eval { 
		my @tc = `infocmp -C $term`;
		chomp(@tc);
		splice(@tc, 0, 1); # remove header line
		$ENV{TERMCAP} = join("", @tc);
		$termcap = Term::Cap->Tgetent( { TERM => $term, OSPEED => $ospeed } );
		$termcap->Trequire($tc_left);
	    };
	}
	die "POE::Wheel::ReadLine requires a termcap that supports LE or le" if $@;
    }

    # Terminal size.
    # We initialise the values once on startup,
    # and then from then on, we check them on every entry into
    # the input state engine (so that we have valid values) and
    # before handing control back to the user (so that they get
    # an up-to-date value).
    ($trk_cols, $trk_rows) = Term::ReadKey::GetTerminalSize($stdout);

    # Set up console using Term::ReadKey.
    ReadMode('ultra-raw');
    # And tell the terminal that we want to be in 'application' mode
    print $termcap->Tputs('ks' => 1) if $termcap->Tputs('ks');

    # Configuration...
    # Some things are optional.
    eval { $termcap->Trequire( 'ce' ) };
    $tc_has_ce = 1 unless $@;

    # o/` You can ring my bell, ring my bell. o/`
    my $bell = $termcap->Tputs( bl => 1 );
    $bell = $termcap->Tputs( vb => 1 ) unless defined $bell;
    $tc_bell = (defined $bell) ? $bell : '';
    $bell = $termcap->Tputs( vb => 1 ) || '';
    $tc_visual_bell = $bell;

    my $convert_meta = 1;
    for (my $ord = 0; $ord < 256; $ord++) {
	my $str = chr($ord);
	if ($ord > 126) {
	    if ($convert_meta) {
		$str = "^[";
		if (($ord - 128) < 32) {
		    $str .= "^" . lc(chr($ord-128+64));
		} else {
		    $str .= lc(chr($ord-128));
		}
	    } else {
		$str = sprintf "<%2x>", $ord;
	    }
	} elsif ($ord < 32) {
	    $str = '^' . lc(chr($ord+64));
	}
	$normalized_character{chr($ord)} = $str;
	$normalized_extra_width[$ord] = length ( $str ) - 1;
  }
  $initialised++;
}
#------------------------------------------------------------------------------
# The methods themselves.

# Create a new ReadLine wheel.
sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my %params = @_;
  croak "$class requires a working Kernel" unless defined $poe_kernel;

  my $input_event = delete $params{InputEvent};
  croak "$class requires an InputEvent parameter" unless defined $input_event;

  my $put_mode = delete $params{PutMode};
  $put_mode = 'idle' unless defined $put_mode;
  croak "$class PutMode must be either 'immediate', 'idle', or 'after'"
    unless $put_mode =~ /^(immediate|idle|after)$/;

  my $idle_time = delete $params{IdleTime};
  $idle_time = 2 unless defined $idle_time;

  my $app = delete $params{appname};
  $app ||= 'poe-readline';

  if (scalar keys %params) {
    carp( "unknown parameters in $class constructor call: ",
          join(', ', keys %params)
        );
  }

  my $self = undef;
  if (ref $proto) {
      $self = bless [], $class;
      @$self = @$proto;
      $self->[SELF_SOURCE] = $proto;
      $poe_kernel->select_read($stdin); # ensure we're not bound to the old handler
  } else {
      $self = bless
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
	  &POE::Wheel::allocate_wheel_id(),  # SELF_UNIQUE_ID
	  undef,        # SELF_KEYMAP
	  { },          # SELF_OPTIONS
	  $app,         # SELF_APP
	  {},           # SELF_ALL_KEYMAPS
	  undef,        # SELF_PENDING
	  0,            # SELF_COUNT
	  0,            # SELF_MARK
	  {},           # SELF_MARKLIST
	  [],           # SELF_KILL_RING
	  '',           # SELF_LAST
	  undef,        # SELF_PENDING_FN
	  undef,        # SELF_SOURCE
	  '',           # SELF_SEARCH
	  undef,        # SELF_SEARCH_PROMPT
	  undef,        # SELF_SEARCH_MAP
	  '',           # SELF_PREV_PROMPT
	  0,            # SELF_SEARCH_DIR
	  '',           # SELF_SEARCH_KEY
	  [],           # SELF_UNDO
	], $class;

      global_init();
      $self->rl_re_read_init_file();
  }

  # Turn off $stdout buffering.
  select((select($stdout), $| = 1)[0]);

  # Set up the event handlers.  Idle goes first.
  $self->[SELF_STATE_IDLE] = ref($self) . "(" . $self->[SELF_UNIQUE_ID] . ") -> input timeout",
  $poe_kernel->state($self->[SELF_STATE_IDLE], $self, 'idle_state');

  $self->[SELF_STATE_READ] = ref($self) . "(" . $self->[SELF_UNIQUE_ID] . ") -> select read";
  $poe_kernel->state($self->[SELF_STATE_READ], $self, 'read_state');

  return $self;
}

#------------------------------------------------------------------------------
# Destroy the ReadLine wheel.  Clean up the terminal.

sub DESTROY {
  my $self = shift;

  # Stop selecting on the handle.
  $poe_kernel->select($stdin);

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

  # tell the terminal that we want to leave 'application' mode
  print $termcap->Tputs('ke' => 1) if $termcap->Tputs('ke');
  # Restore the console.
  ReadMode('restore');

  &POE::Wheel::free_wheel_id($self->[SELF_UNIQUE_ID]);
}

#------------------------------------------------------------------------------
# Redefine the idle handler.  This also uses stupid closure tricks.
# See the comments for &_define_read_state for more information about
# these closure tricks.

sub idle_state {
    my ($self) = $_[OBJECT];

    if (@{$self->[SELF_PUT_BUFFER]}) {
	$self->wipe_input_line;
	$self->flush_output_buffer;
	$self->repaint_input_line;
    }

    # No more timer.
    $self->[SELF_HAS_TIMER] = 0;
}

sub read_state {
    my ($self, $k) = @_[OBJECT, KERNEL];

    # Read keys, non-blocking, as long as there are some.
    while (defined(my $raw_key = ReadKey(-1))) {
	
	# Not reading a line; discard the input.
	next unless $self->[SELF_READING_LINE];
	
	# Update the timer on significant input.
	if ( $self->[SELF_PUT_MODE] eq 'idle' ) {
	    $k->delay( $self->[SELF_STATE_IDLE], $self->[SELF_IDLE_TIME] );
	    $self->[SELF_HAS_TIMER] = 1;
	}
	
	push(@{$self->[SELF_UNDO]}, [ $self->[SELF_INPUT], 
				      $self->[SELF_CURSOR_INPUT], 
				      $self->[SELF_CURSOR_DISPLAY] ]);

	# Build-multi character codes and make the keystroke printable.
	$self->[SELF_KEY_BUILD] .= $raw_key;
	$raw_key = $self->[SELF_KEY_BUILD];
	my $key = normalize($raw_key);

	if ($self->[SELF_PENDING_FN]) {
	    my $old = $self->[SELF_INPUT];
	    my $oldref = $self->[SELF_PENDING_FN];
	    push(@{$self->[SELF_UNDO]}, [ $old,
					  $self->[SELF_CURSOR_INPUT], 
					  $self->[SELF_CURSOR_DISPLAY] ]);
	    &{$self->[SELF_PENDING_FN]}($key, $raw_key);
	    pop(@{$self->[SELF_UNDO]}) if ($old eq $self->[SELF_INPUT]);
	    $self->[SELF_KEY_BUILD] = '';
	    if ($self->[SELF_PENDING_FN] && "$self->[SELF_PENDING_FN]" eq $oldref) {
		$self->[SELF_PENDING_FN] = undef;
	    }
	    next;
	}

	# Keep glomming keystrokes until they stop existing in the
	# hash of meta prefixes.
	next if exists $self->[SELF_KEYMAP]->{prefix}->{$raw_key};

	# PROCESS KEY
	my $old = $self->[SELF_INPUT];
	push(@{$self->[SELF_UNDO]}, [ $old,
				      $self->[SELF_CURSOR_INPUT], 
				      $self->[SELF_CURSOR_DISPLAY] ]);
	$self->[SELF_KEY_BUILD] = '';
	$self->apply_key($key, $raw_key);

	pop(@{$self->[SELF_UNDO]}) if ($old eq $self->[SELF_INPUT]);
    }
}

sub apply_key {
    my ($self, $key, $raw_key) = @_;
    my $mapping = $self->[SELF_KEYMAP];
    my $fn = $mapping->{default};
    if (exists $mapping->{binding}->{$raw_key}) {
	$fn = $mapping->{binding}->{$raw_key};
    }
    #print "\r\ninvoking $fn for $key\r\n";$self->repaint_input_line;
    if ($self->[SELF_COUNT] && !grep { $_ eq $fn } @fns_counting) {
	$self->[SELF_COUNT] = int($self->[SELF_COUNT]);
	$self->[SELF_COUNT] ||= 1;
	while ($self->[SELF_COUNT] > 0) {
	    if (ref $fn) {
		$self->$fn($key, $raw_key);
	    } else {
		&{$defuns->{$fn}}($self, $key, $raw_key);
	    }
	    $self->[SELF_COUNT]--;
	}
	$self->[SELF_COUNT] = "";
    } else {
	if (ref $fn) {
	    $self->$fn($key, $raw_key);
	} else {
	    &{$defuns->{$fn}}($self, $key, $raw_key);
	}
    }
    $self->[SELF_LAST] = $fn unless grep { $_ eq $fn } @fns_anon;
}

# Send a prompt; get a line.
sub get {
  my ($self, $prompt) = @_;

  # Already reading a line here, people.  Sheesh!
  return if $self->[SELF_READING_LINE];
  # recheck the terminal size every prompt, in case the size
  # has changed
  ($trk_cols, $trk_rows) = Term::ReadKey::GetTerminalSize($stdout);

  # Set up for the read.
  $self->[SELF_READING_LINE]   = 1;
  $self->[SELF_PROMPT]         = $prompt;
  $self->[SELF_INPUT]          = '';
  $self->[SELF_CURSOR_INPUT]   = 0;
  $self->[SELF_CURSOR_DISPLAY] = 0;
  $self->[SELF_HIST_INDEX]     = @{$self->[SELF_HIST_LIST]};
  $self->[SELF_INSERT_MODE]    = 1;
  $self->[SELF_UNDO]           = [];
  $self->[SELF_LAST]           = '';

  # Watch the filehandle.
  $poe_kernel->select($stdin, $self->[SELF_STATE_READ]);

  my $sp = $prompt;
  $sp =~ s{\\[\[\]]}{}g;

  print $stdout $sp;
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

      # Only clear the input line if we're reading input already
      $self->wipe_input_line if ($self->[SELF_READING_LINE]);

      # Print the new stuff.
      $self->flush_output_buffer;
      print $stdout @lines;

      # Only repaint the input if we're reading a line.
      $self->repaint_input_line if ($self->[SELF_READING_LINE]);

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

# Clear the screen.
sub clear {
  my $self = shift;
  $termcap->Tputs( cl => 1, $stdout );
}

sub terminal_size {
    return ($trk_cols, $trk_rows);
}

# Add things to the edit history.
sub addhistory {
    my $self = shift;
    push @{$self->[SELF_HIST_LIST]}, @_;
}

sub GetHistory {
    my $self = shift;
    return @{$self->[SELF_HIST_LIST]};
}
sub WriteHistory {
    my ($self, $file) = @_;
    $file ||= "$ENV{HOME}/.history";
    open(HIST, ">$file") || return undef;
    print HIST join("\n", @{$self->[SELF_HIST_LIST]}) . "\n";
    close(HIST);
    return 1;
}
sub ReadHistory {
    my ($self, $file, $from, $to) = @_;
    $from ||= 0;
    $to = -1 unless defined $to;
    $file ||= "$ENV{HOME}/.history";
    open(HIST, $file) or return undef;
    my @hist = <HIST>;
    close(HIST);
    my $line = 0;
    foreach my $h (@hist) {
	chomp($h);
	$self->addhistory($h) if ($line >= $from && ($to < $from || $line <= $to));
	$line++;
    }
    return 1;
}

sub history_truncate_file {
    my ($self, $file, $lines) = @_;
    $lines ||= 0;
    $file ||= "$ENV{HOME}/.history";
    open(HIST, $file) or return undef;
    my @hist = <HIST>;
    close(HIST);
    if ((scalar @hist) > $lines) {
	open(HIST, ">$file") or return undef;
	if ($lines) {
	    splice(@hist, -$lines);
	    print HIST @{$self->[SELF_HIST_LIST]} = @hist;
	} else {
	    @{$self->[SELF_HIST_LIST]} = ();
	}
	close(HIST);
    }
    return 1;
}

# Get the wheel's ID.
sub ID {
  return $_[0]->[SELF_UNIQUE_ID];
}

sub Attribs {
    my ($self) = @_;
    return $self->[SELF_OPTIONS];
}

sub option {
    my ($self, $arg) = @_;
    $arg = lc($arg);
    return "" unless exists $self->[SELF_OPTIONS]->{$arg};
    return $self->[SELF_OPTIONS]->{$arg};
}

sub init_keymap {
    my ($self, $default, @names) = @_;
    my $name = $names[0];
    if (!exists $defuns->{$default}) {
	die("cannot initialise keymap $name, since default function $default is unknown")
    }
    my $map = POE::Wheel::ReadLine::Keymap->init(default => $default, name => $name, termcap => $termcap);
    foreach my $n (@names) {
	$self->[SELF_ALL_KEYMAPS]->{$n} = $map;
    }
    return $map;
}

sub rl_re_read_init_file {
    my ($self) = @_;

    $self->init_keymap('self-insert', 'emacs');
    $self->init_keymap('ding', 'vi-command', 'vi');
    $self->init_keymap('self-insert', 'vi-insert');

    # searching
    my $isearch = $self->init_keymap('search-finish', 'isearch');
    my $vi_search = $self->init_keymap('search-finish', 'vi-search');
    $self->parse_inputrc($search_inputrc);

    # A keymap to take the VI range specification commands
    # used by the -to commands (e.g. change-to, etc)
    $self->init_keymap('vi-end-spec', 'vi-specification');

    $self->parse_inputrc($defaults_inputrc);

    $self->rl_set_keymap('vi');
    $self->parse_inputrc($vi_inputrc);

    $self->rl_set_keymap('emacs');
    $self->parse_inputrc($emacs_inputrc);

    my $personal = exists $ENV{INPUTRC} ? $ENV{INPUTRC} : "$ENV{HOME}/.inputrc";
    foreach my $file ($personal) {
	my $input = "";
	if (open(IN, $file)) {
	    local $/ = undef;
	    $input = <IN>;
	    close(IN);
	    $self->parse_inputrc($input);
	}
    }	
    if (!$self->option('editing-mode')) {
        if (exists $ENV{EDITOR} && $ENV{EDITOR} =~ /vi/) {
	    $self->[SELF_OPTIONS]->{'editing-mode'} = 'vi';
	} else {
	    $self->[SELF_OPTIONS]->{'editing-mode'} = 'emacs';
	}
    }
    if ($self->option('editing-mode') eq 'vi') {
	$self->rl_set_keymap('vi-insert'); # by default, start in insert mode already
    }

    my $isearch_term = $self->option('isearch-terminators') || 'C-[ C-J';
    foreach my $key (split(/\s+/, $isearch_term)) {
	$isearch->bind_key($key, 'search-abort');
    }
    foreach my $key (ord(' ') .. ord('~')) {
	$isearch->bind_key('"' . chr($key) . '"', 'search-key');
	$vi_search->bind_key('"' . chr($key) . '"', 'vi-search-key');
    }
}

sub parse_inputrc {
    my ($self, $input, $depth) = @_;
    $depth ||= 0;
    my @cond = (); # allows us to nest conditionals.

    foreach my $line (split(/\n+/, $input)) {
	next if $line =~ /^#/;
	if ($line =~ /^\$(.*)/) {
	    my (@parms) = split(/[ 	+=]/,$1);
	    if ($parms[0] eq 'if') {
		my $bool = 0;
		if ($parms[1] eq 'mode') {
		    if ($self->option('editing-mode') eq $parms[2]) {
			$bool = 1;
		    }
		} elsif ($parms[1] eq 'term') {
		    my ($half, $full) = ($ENV{TERM} =~ /^([^-]*)(-.*)?$/);
		    if ($half eq $parms[2] || ($full && $full eq $parms[2])) {
			$bool = 1;
		    }
		} elsif ($parms[1] eq $self->[SELF_APP]) {
		    $bool = 1;
		}
		push(@cond, $bool);
	    } elsif ($parms[0] eq 'else') {
		$cond[$#cond] = not $cond[$#cond];
	    } elsif ($parms[0] eq 'endif') {
		pop(@cond);
	    } elsif ($parms[0] eq 'include') {
		if ($depth > 10) {
		    print STDERR "WARNING: ignoring 'include $parms[1] directive, since we're too deep";
		} else {
		    $self->parse_inputrc($input, $depth+1);
		}
	    }
	} else {
	    next if (scalar @cond and not $cond[$#cond]);
	    if ($line =~ /^set\s+([\S]+)\s+([\S]+)/) {
		my ($var,$val) = ($1, $2);
		$self->[SELF_OPTIONS]->{lc($var)} = $val;
		my $fn = "rl_set_" . lc($var);
		$fn =~ s{-}{_}g;
		if ($self->can($fn)) {
		    $self->$fn($self->[SELF_OPTIONS]->{$var});
		}
	    } elsif ($line =~ /^([^:]+):\s*(.*)/) {
		my ($seq, $fn) = ($1, lc($2));
		chomp($fn);
		$self->[SELF_KEYMAP]->bind_key($seq, $fn);
	    }
	}
    }
}

# take a key and output it in a form nice to read...
sub dump_key_line {
    my ($self, $key, $raw_key) = @_;
    if (exists $self->[SELF_KEYMAP]->{prefix}->{$raw_key}) {
	$self->[SELF_PENDING_FN] = sub { 
	    my ($k, $rk) = @_;
	    $self->dump_key_line($key.$k, $raw_key.$rk);
	};
	return;
    }

    my $fn = $self->[SELF_KEYMAP]->{default};
    if (exists $self->[SELF_KEYMAP]->{binding}->{$raw_key}) {
	    $fn = $self->[SELF_KEYMAP]->{binding}->{$raw_key};
	}
    if (ref $fn) {
	$fn = "[coderef]";
    }

    print "\x0D\x0A" . readable_key($raw_key) . ": " . $fn . "\x0D\x0A";
    $self->repaint_input_line;
}

sub bind_key {
    my ($self, $seq, $fn, $map) = @_;
    $map ||= $self->[SELF_KEYMAP];
    $map->bind_key($seq, $fn);
}

sub add_defun {
    my ($self, $name, $fn) = @_;
    $defuns->{$name} = $fn;
}

# ====================================================
# Any variable assignments that we care about
# ====================================================
sub rl_set_keymap {
    my ($self, $arg) = @_;
    $arg = lc($arg);
    if (exists $self->[SELF_ALL_KEYMAPS]->{$arg}) {
	$self->[SELF_KEYMAP] = $self->[SELF_ALL_KEYMAPS]->{$arg};
	$self->[SELF_OPTIONS]->{keymap} = $self->[SELF_KEYMAP]->{name};
    }
    # always reset overstrike mode on keymap change
    $self->[SELF_INSERT_MODE] = 1;
}

# ====================================================
# From here on, we have the helper functions which can
# be bound to keys. The functions are named after the
# readline counterparts.
# ====================================================

sub rl_self_insert {
    my ($self, $key, $raw_key) = @_;

    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	if ($self->[SELF_INSERT_MODE]) {
	    # Insert.
	    my $normal = normalize(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]));
	    substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 0) = $raw_key;
	    print $stdout $key, $normal;
	    $self->[SELF_CURSOR_INPUT] += length($raw_key);
	    $self->[SELF_CURSOR_DISPLAY] += length($key);
	    curs_left(length($normal));
	} else {
	    # Overstrike.
	    my $replaced_width =
	      display_width
		( substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], length($raw_key))
		);
	    substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], length($raw_key)) = $raw_key;

	    print $stdout $key;
	    $self->[SELF_CURSOR_INPUT] += length($raw_key);
	    $self->[SELF_CURSOR_DISPLAY] += length($key);

	    # Expand or shrink the display if unequal replacement.
	    if (length($key) != $replaced_width) {
		my $rest = normalize(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]));
		# Erase trailing screen cruft if it's shorter.
		if (length($key) < $replaced_width) {
		    $rest .= ' ' x ($replaced_width - length($key));
		}
		print $stdout $rest;
		curs_left(length($rest));
	    }
	}
    } else {
	# Append.
	print $stdout $key;
	$self->[SELF_INPUT] .= $raw_key;
	$self->[SELF_CURSOR_INPUT] += length($raw_key);
	$self->[SELF_CURSOR_DISPLAY] += length($key);
    }
}

sub rl_insert_macro {
    my ($self, $key) = @_;
    my $macro = $self->[SELF_KEYMAP]->{macros}->{$key};
    $macro =~ s{\\a}{$tc_bell}g;
    $macro =~ s{\\r}{\r}g;
    $macro =~ s{\\n}{\n}g;
    $macro =~ s{\\t}{\t}g;
    $self->rl_self_insert($macro, $macro);
}

sub rl_insert_comment {
    my ($self) = @_;
    my $comment = $self->option('comment-begin');
    $self->wipe_input_line;
    if ($self->[SELF_COUNT]) {
	if (substr($self->[SELF_INPUT], 0, length($comment)) eq $comment) {
	    substr($self->[SELF_INPUT], 0, length($comment)) = "";
	} else {
	    $self->[SELF_INPUT] = $comment . $self->[SELF_INPUT];
	}
	$self->[SELF_COUNT] = 0;
    } else {
	$self->[SELF_INPUT] = $comment . $self->[SELF_INPUT];
    }
    $self->repaint_input_line;
    $self->rl_accept_line;
}

sub rl_revert_line {
    my ($self) = @_;
    return $self->rl_ding unless scalar @{$self->[SELF_UNDO]};
    $self->wipe_input_line;
    ($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], $self->[SELF_CURSOR_DISPLAY])
      = @{$self->[SELF_UNDO]->[0]};
    $self->[SELF_UNDO] = [];
    $self->repaint_input_line;
}

sub rl_yank_last_arg {
    my ($self) = @_;
    if ($self->[SELF_HIST_INDEX] == 0) {
	return $self->rl_ding;
    }
    if ($self->[SELF_COUNT]) {
	return &rl_yank_nth_arg;
    }
    my $prev = $self->[SELF_HIST_LIST]->[$self->[SELF_HIST_INDEX]-1];
    my ($arg) = ($prev =~ m{(\S+)$});
    $self->rl_self_insert($arg, $arg);
    1;
}

sub rl_yank_nth_arg {
    my ($self) = @_;
    if ($self->[SELF_HIST_INDEX] == 0) {
	return $self->rl_ding;
    }
    my $prev = $self->[SELF_HIST_LIST]->[$self->[SELF_HIST_INDEX]-1];
    my @args = split(/\s+/, $prev);
    my $pos = $self->[SELF_COUNT] || 1;
    $self->[SELF_COUNT] = 0;
    if ($pos < 0) {
	$pos = (scalar @args) + $pos;
    }
    if ($pos > scalar @args || $pos < 0) {
	return $self->rl_ding;
    }
    $self->rl_self_insert($args[$pos], $args[$pos]);
}

sub rl_dump_key {
    my ($self) = @_;
    $self->[SELF_PENDING_FN] = sub { my ($k,$rk) = @_; $self->dump_key_line($k, $rk) };
}

sub rl_dump_macros {
    my ($self) = @_;
    print $stdout "\x0D\x0A";
    my $c = 0;
    foreach my $macro (keys %{$self->[SELF_KEYMAP]->{macros}}) {
	print $stdout '"' . normalize($macro) . "\": \"$self->[SELF_KEYMAP]->{macros}->{$macro}\"\x0D\x0A";
	$c++;
    }
    if (!$c) {
	print "# no macros defined\x0D\x0A";
    }
    $self->repaint_input_line;
}

sub rl_dump_variables {
    my ($self) = @_;
    print $stdout "\x0D\x0A";
    my $c = 0;
    foreach my $var (keys %{$self->[SELF_OPTIONS]}) {
	print $stdout "set $var $self->[SELF_OPTIONS]->{$var}\x0D\x0A";
	$c++;
    }
    if (!$c) {
	print "# no variables defined\x0D\x0A";
    }
    $self->repaint_input_line;
}

sub rl_set_mark {
    my ($self) = @_;
    if ($self->[SELF_COUNT]) {
	$self->[SELF_MARK] = $self->[SELF_COUNT];
    } else {
	$self->[SELF_MARK] = $self->[SELF_CURSOR_INPUT];
    }
    $self->[SELF_COUNT] = 0;
}

sub rl_digit_argument {
    my ($self, $key) = @_;
    $self->[SELF_COUNT] .= $key;
}

sub rl_beginning_of_line {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT]) {
	curs_left($self->[SELF_CURSOR_DISPLAY]);
	$self->[SELF_CURSOR_DISPLAY] = $self->[SELF_CURSOR_INPUT] = 0;
    }
}

sub rl_end_of_line {
    my ($self, $key) = @_;
    my $max = length($self->[SELF_INPUT]);
    $max-- if ($self->[SELF_KEYMAP]->{name} =~ /vi/);
    if ($self->[SELF_CURSOR_INPUT] < $max) {
	my $right_string = substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]);
	print normalize($right_string);
	my $right = display_width($right_string);
	if ($self->[SELF_KEYMAP]->{name} =~ /vi/) {
	    $self->[SELF_CURSOR_DISPLAY] += $right - 1;
	    $self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]) - 1;
	    curs_left(1);
	} else {
	    $self->[SELF_CURSOR_DISPLAY] += $right;
	    $self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]);
	}
    }
}

sub rl_backward_char {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT]) {
	$self->[SELF_CURSOR_INPUT]--;
	my $left = display_width(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1));
	curs_left($left);
	$self->[SELF_CURSOR_DISPLAY] -= $left;
    }
    else {
	$self->rl_ding;
    }
}

sub rl_forward_char {
    my ($self, $key) = @_;
    my $max = length($self->[SELF_INPUT]);
    $max-- if ($self->[SELF_KEYMAP]->{name} =~ /vi/);
    if ($self->[SELF_CURSOR_INPUT] < $max) {
	my $normal = normalize(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1));
	print $stdout $normal;
	$self->[SELF_CURSOR_INPUT]++;
	$self->[SELF_CURSOR_DISPLAY] += length($normal);
    } else {
	$self->rl_ding;
    }
}

sub rl_forward_word {
    my ($self, $key) = @_;
    if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\W*\w+)/) {
	$self->[SELF_CURSOR_INPUT] += length($1);
	my $right = display_width($1);
	print normalize($1);
	$self->[SELF_CURSOR_DISPLAY] += $right;
    } else {
	$self->rl_ding;
    }
}

sub rl_backward_word {
    my ($self, $key) = @_;
    if (substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~ /(\w+\W*)$/) {
	$self->[SELF_CURSOR_INPUT] -= length($1);
	my $left = display_width($1);
	curs_left($left);
	$self->[SELF_CURSOR_DISPLAY] -= $left;
    } else {
	$self->rl_ding;
    }
}

sub rl_backward_kill_word {
    my ($self) = @_;
    if ($self->[SELF_CURSOR_INPUT]) {
	substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~ /(\w*\W*)$/;
	my $kill = $self->delete_chars($self->[SELF_CURSOR_INPUT] - length($1), length($1));
	push(@{$self->[SELF_KILL_RING]}, $kill);
    } else {
	$self->rl_ding;
    }
}

sub rl_kill_region {
    my ($self) = @_;
    my $kill = $self->delete_chars($self->[SELF_CURSOR_INPUT], $self->[SELF_CURSOR_INPUT] - $self->[SELF_MARK]);
    push(@{$self->[SELF_KILL_RING]}, $kill);
}

sub rl_kill_word {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ s/^(\W*\w*\W*)//;
	my $kill = $self->delete_chars($self->[SELF_CURSOR_INPUT], length($1));
	push(@{$self->[SELF_KILL_RING]}, $kill);
    } else {
	$self->rl_ding;
    }
}
sub rl_kill_line {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	my $kill = $self->delete_chars($self->[SELF_CURSOR_INPUT], length($self->[SELF_INPUT]) - $self->[SELF_CURSOR_INPUT]);
	push(@{$self->[SELF_KILL_RING]}, $kill);
    } else {
	$self->rl_ding;
    }
}

sub rl_unix_word_rubout {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT]) {
	substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~ /(\S*\s*)$/;
	my $kill = $self->delete_chars($self->[SELF_CURSOR_INPUT] - length($1), length($1));
	push(@{$self->[SELF_KILL_RING]}, $kill);
    } else {
	$self->rl_ding;
    }
}

sub rl_delete_horizontal_space {
    my ($self) = @_;
    substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~ /(\s*)$/;
    my $left = length($1);
    substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*)/;
    my $right = length($1);

    if ($left + $right) {
	$self->delete_chars($self->[SELF_CURSOR_INPUT] - $left, $left + $right);
    } else {
	$self->rl_ding;
    }
}

sub rl_copy_region_as_kill {
    my ($self) = @_;
    my $from = $self->[SELF_CURSOR_INPUT];
    my $howmany = $self->[SELF_CURSOR_INPUT] - $self->[SELF_MARK];
    if ($howmany < 0) {
	$from -= $howmany;
	$howmany = -$howmany;
	if ($from < 0) {
	    $howmany -= $from;
	    $from = 0;
	}
    }
    my $old = substr($self->[SELF_INPUT], $from, $howmany);
    push(@{$self->[SELF_KILL_RING]}, $old);
}

sub rl_abort {
    my ($self, $key) = @_;
    print $stdout uc($key), "\x0D\x0A";
    $poe_kernel->select_read($stdin);
    if ($self->[SELF_HAS_TIMER]) {
	$poe_kernel->delay( $self->[SELF_STATE_IDLE] );
	$self->[SELF_HAS_TIMER] = 0;
    }
    $poe_kernel->yield( $self->[SELF_EVENT_INPUT], undef, 'cancel',
			$self->[SELF_UNIQUE_ID]
		      );
    $self->[SELF_READING_LINE] = 0;
    $self->[SELF_HIST_INDEX] = @{$self->[SELF_HIST_LIST]};
    $self->flush_output_buffer;
}

sub rl_interrupt {
    my ($self, $key) = @_;
    print $stdout uc($key), "\x0D\x0A";
    $poe_kernel->select_read($stdin);
    if ($self->[SELF_HAS_TIMER]) {
	$poe_kernel->delay( $self->[SELF_STATE_IDLE] );
	$self->[SELF_HAS_TIMER] = 0;
    }
    $poe_kernel->yield( $self->[SELF_EVENT_INPUT], undef, 'interrupt', $self->[SELF_UNIQUE_ID] );
    $self->[SELF_READING_LINE] = 0;
    $self->[SELF_HIST_INDEX] = @{$self->[SELF_HIST_LIST]};

    $self->flush_output_buffer;
}

# Delete a character.  On an empty line, it throws an
# "eot" exception, just like Term::ReadLine does.
sub rl_delete_char {
    my ($self, $key) = @_;
    if (length $self->[SELF_INPUT] == 0) {
	print $stdout uc($key), "\x0D\x0A";
	$poe_kernel->select_read($stdin);
	if ($self->[SELF_HAS_TIMER]) {
	    $poe_kernel->delay( $self->[SELF_STATE_IDLE] );
	    $self->[SELF_HAS_TIMER] = 0;
	}
	$poe_kernel->yield( $self->[SELF_EVENT_INPUT], undef, "eot",
			    $self->[SELF_UNIQUE_ID]
			  );
	$self->[SELF_READING_LINE] = 0;
	$self->[SELF_HIST_INDEX] = @{$self->[SELF_HIST_LIST]};
	
	$self->flush_output_buffer;
	return;
    }

    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	$self->delete_chars($self->[SELF_CURSOR_INPUT], 1);
    } else {
	$self->rl_ding;
    }
}

sub rl_backward_delete_char {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT]) {
	$self->delete_chars($self->[SELF_CURSOR_INPUT]-1, 1);
    } else {
	$self->rl_ding;
    }
}

sub rl_accept_line {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	my $right_string = substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]);
	print normalize($right_string);
	my $right = display_width($right_string);
	$self->[SELF_CURSOR_DISPLAY] += $right;
	$self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]);
    }
    # home the cursor.
    $self->[SELF_CURSOR_DISPLAY] = 0;
    $self->[SELF_CURSOR_INPUT] = 0;
    print $stdout "\x0D\x0A";
    $poe_kernel->select_read($stdin);
    if ($self->[SELF_HAS_TIMER]) {
	$poe_kernel->delay( $self->[SELF_STATE_IDLE] );
	$self->[SELF_HAS_TIMER] = 0;
    }
    $poe_kernel->yield( $self->[SELF_EVENT_INPUT], $self->[SELF_INPUT], $self->[SELF_UNIQUE_ID] );
    $self->[SELF_READING_LINE] = 0;
    $self->[SELF_HIST_INDEX] = @{$self->[SELF_HIST_LIST]};
    $self->flush_output_buffer;
    ($trk_cols, $trk_rows) = Term::ReadKey::GetTerminalSize($stdout);
    if ($self->[SELF_KEYMAP]->{name} =~ /vi/) {
	$self->rl_set_keymap('vi-insert');
    }
}

sub rl_clear_screen {
    my ($self, $key) = @_;
    my $left = display_width(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]));
    $termcap->Tputs( 'cl', 1, $stdout );
    my $sp = $self->[SELF_PROMPT];
    $sp =~ s{\\[\[\]]}{}g;
    print $stdout $sp, normalize($self->[SELF_INPUT]);
    curs_left($left) if $left;
}

sub rl_transpose_chars {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT] > 0 and $self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	my $width_left =
	  display_width(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT] - 1, 1));
	
	my $transposition =
	  reverse substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT] - 1, 2);
	substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT] - 1, 2) = $transposition;
	
	curs_left($width_left);
	print $stdout normalize($transposition);
	curs_left($width_left);
    } else {
	$self->rl_ding;
    }
}

sub rl_transpose_words {
    my ($self, $key) = @_;
    my ($previous, $left, $space, $right, $rest);

    # This bolus of code was written to replace a single
    # regexp after finding out that the regexp's negative
    # zero-width look-behind assertion doesn't work in
    # perl 5.004_05.  For the record, this is that regexp:
    # s/^(.{0,$cursor_sub_one})(?<!\S)(\S+)(\s+)(\S+)/$1$4$3$2/

    if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1) =~ /\s/) {
	my ($left_space, $right_space);
	($previous, $left, $left_space) =
	  ( substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~
	    /^(.*?)(\S+)(\s*)$/
	  );
	($right_space, $right, $rest) =
	  ( substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~
	    /^(\s+)(\S+)(.*)$/);
	$space = $left_space . $right_space;
    } elsif ( substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~
	    /^(.*?)(\S+)(\s+)(\S*)$/
	  ) {
	($previous, $left, $space, $right) = ($1, $2, $3, $4);
	if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\S*)(.*)$/) {
	    $right .= $1 if defined $1;
	    $rest = $2;
	}
    } elsif ( substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~
	    /^(\S+)(\s+)(\S+)(.*)$/
	  ) {
	($left, $space, $right, $rest) = ($1, $2, $3, $4);
	if ( substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~ /^(.*?)(\S+)$/ ) {
	    $previous = $1;
	    $left = $2 . $left;
	}
    } else {
	$self->rl_ding;
	next;
    }

    $previous = '' unless defined $previous;
    $rest     = '' unless defined $rest;

    $self->[SELF_INPUT] = $previous . $right . $space . $left . $rest;

    if ($self->[SELF_CURSOR_DISPLAY] - display_width($previous)) {
	curs_left($self->[SELF_CURSOR_DISPLAY] - display_width($previous));
    }
    print $stdout normalize($right . $space . $left);
    $self->[SELF_CURSOR_INPUT] = length($previous. $left . $space . $right);
    $self->[SELF_CURSOR_DISPLAY] =
      display_width($previous . $left . $space . $right);
}

sub rl_unix_line_discard {
    my ($self, $key) = @_;
    if (length $self->[SELF_INPUT]) {
	my $kill = $self->delete_chars(0, $self->[SELF_CURSOR_INPUT]);
	push(@{$self->[SELF_KILL_RING]}, $kill);
    } else {
	$self->rl_ding;
    }
}

sub rl_kill_whole_line {
    my ($self, $key) = @_;
    if (length $self->[SELF_INPUT]) {
	# Back up to the beginning of the line.
	if ($self->[SELF_CURSOR_INPUT]) {
	    curs_left($self->[SELF_CURSOR_DISPLAY]);
	    $self->[SELF_CURSOR_DISPLAY] = $self->[SELF_CURSOR_INPUT] = 0;
	}
	$self->clear_to_end;
	
	# Clear the input buffer.
	push(@{$self->[SELF_KILL_RING]}, $self->[SELF_INPUT]);
	$self->[SELF_INPUT] = '';
    } else {
	$self->rl_ding;
    }
}

sub rl_yank {
    my ($self) = @_;
    my $pos = scalar @{$self->[SELF_KILL_RING]};
    return $self->rl_ding unless ($pos);

    $pos--;
    $self->rl_self_insert($self->[SELF_KILL_RING]->[$pos], $self->[SELF_KILL_RING]->[$pos]);
}

sub rl_yank_pop {
    my ($self) = @_;
    return $self->rl_ding unless ($self->[SELF_LAST] =~ /yank/);
    my $pos = scalar @{$self->[SELF_KILL_RING]};
    return $self->rl_ding unless ($pos);

    my $top = pop @{$self->[SELF_KILL_RING]};
    unshift(@{$self->[SELF_KILL_RING]}, $top);
    $self->rl_yank;
}

sub rl_previous_history {
    my ($self, $key) = @_;
    if ($self->[SELF_HIST_INDEX]) {
	# Moving away from a new input line; save it in case
	# we return.
	if ($self->[SELF_HIST_INDEX] == @{$self->[SELF_HIST_LIST]}) {
	    $self->[SELF_INPUT_HOLD] = $self->[SELF_INPUT];
	}
	
	# Move cursor to start of input.
	if ($self->[SELF_CURSOR_INPUT]) {
	    curs_left($self->[SELF_CURSOR_DISPLAY]);
	}
	$self->clear_to_end;
	
	# Move the history cursor back, set the new input
	# buffer, and show what the user's editing.  Set the
	# cursor to the end of the new line.
	my $normal;
	print $stdout $normal =
	  normalize($self->[SELF_INPUT] = $self->[SELF_HIST_LIST]->[--$self->[SELF_HIST_INDEX]]);
	$self->[SELF_UNDO] = [ [ $self->[SELF_INPUT], 0, 0 ] ]; # reset undo info
	$self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]);
	$self->[SELF_CURSOR_DISPLAY] = length($normal);
	$self->rl_backward_char if (length($self->[SELF_INPUT]) && $self->[SELF_KEYMAP]->{name} =~ /vi/);
    } else {
	# At top of history list.
	$self->rl_ding;
    }
}

sub rl_next_history {
    my ($self, $key) = @_;
    if ($self->[SELF_HIST_INDEX] < @{$self->[SELF_HIST_LIST]}) {
	# Move cursor to start of input.
	if ($self->[SELF_CURSOR_INPUT]) {
	    curs_left($self->[SELF_CURSOR_DISPLAY]);
	}
	$self->clear_to_end;
	
	my $normal;
	if (++$self->[SELF_HIST_INDEX] == @{$self->[SELF_HIST_LIST]}) {
	    # Just past the end of the history.  Whatever was
	    # there when we left it.
	    print $stdout $normal = normalize($self->[SELF_INPUT] = $self->[SELF_INPUT_HOLD]);
	} else {
	    # There's something in the history list.  Make that
	    # the current line.
	    print $stdout $normal =
	      normalize($self->[SELF_INPUT] = $self->[SELF_HIST_LIST]->[$self->[SELF_HIST_INDEX]]);
	}
	
	$self->[SELF_UNDO] = [ [ $self->[SELF_INPUT], 0, 0 ] ]; # reset undo info
	$self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]);
	$self->[SELF_CURSOR_DISPLAY] = length($normal);
	$self->rl_backward_char if (length($self->[SELF_INPUT]) && $self->[SELF_KEYMAP]->{name} =~ /vi/);
    } else {
	$self->rl_ding;
    }
}

sub rl_beginning_of_history {
    my ($self) = @_;
    # First in history.
    if ($self->[SELF_HIST_INDEX]) {
	# Moving away from a new input line; save it in case
	# we return.
	if ($self->[SELF_HIST_INDEX] == @{$self->[SELF_HIST_LIST]}) {
	    $self->[SELF_INPUT_HOLD] = $self->[SELF_INPUT];
	}
	
	# Move cursor to start of input.
	if ($self->[SELF_CURSOR_INPUT]) {
	    curs_left($self->[SELF_CURSOR_DISPLAY]);
	}	
	$self->clear_to_end;
	
	# Move the history cursor back, set the new input
	# buffer, and show what the user's editing.  Set the
	# cursor to the end of the new line.
	print $stdout my $normal =
	  normalize($self->[SELF_INPUT] = $self->[SELF_HIST_LIST]->[$self->[SELF_HIST_INDEX] = 0]);
	$self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]);
	$self->[SELF_CURSOR_DISPLAY] = length($normal);
	$self->[SELF_UNDO] = [ [ $self->[SELF_INPUT], 0, 0 ] ]; # reset undo info
    } else {
	# At top of history list.
	$self->rl_ding;
    }
}

sub rl_end_of_history {
    my ($self) = @_;
    if ($self->[SELF_HIST_INDEX] != @{$self->[SELF_HIST_LIST]} - 1) {

	# Moving away from a new input line; save it in case
	# we return.
	if ($self->[SELF_HIST_INDEX] == @{$self->[SELF_HIST_LIST]}) {
	    $self->[SELF_INPUT_HOLD] = $self->[SELF_INPUT];
	}
	
	# Move cursor to start of input.
	if ($self->[SELF_CURSOR_INPUT]) {
	    curs_left($self->[SELF_CURSOR_DISPLAY]);
	}
	$self->clear_to_end;
	
	# Move the edit line down to the last history line.
	$self->[SELF_HIST_INDEX] = @{$self->[SELF_HIST_LIST]} - 1;
	print $stdout my $normal =
	  normalize($self->[SELF_INPUT] = $self->[SELF_HIST_LIST]->[$self->[SELF_HIST_INDEX]]);
	$self->[SELF_CURSOR_INPUT] = length($self->[SELF_INPUT]);
	$self->[SELF_CURSOR_DISPLAY] = length($normal);
	$self->[SELF_UNDO] = [ [ $self->[SELF_INPUT], 0, 0 ] ]; # reset undo info
    } else {
	$self->rl_ding;
    }
}

sub rl_forward_search_history {
    my ($self, $key) = @_;
    $self->wipe_input_line;
    $self->[SELF_PREV_PROMPT] = $self->[SELF_PROMPT];
    $self->[SELF_SEARCH_PROMPT] = '(forward-i-search)`%s\': ';
    $self->[SELF_SEARCH_MAP] = $self->[SELF_KEYMAP];
    $self->[SELF_SEARCH_DIR] = +1;
    $self->[SELF_SEARCH_KEY] = $key;
    $self->build_search_prompt;
    $self->repaint_input_line;
    $self->rl_set_keymap('isearch');
}

sub rl_reverse_search_history {
    my ($self, $key) = @_;
    $self->wipe_input_line;
    $self->[SELF_PREV_PROMPT] = $self->[SELF_PROMPT];
    $self->[SELF_SEARCH_PROMPT] = '(reverse-i-search)`%s\': ';
    $self->[SELF_SEARCH_MAP] = $self->[SELF_KEYMAP];
    $self->[SELF_SEARCH_DIR] = -1;
    $self->[SELF_SEARCH_KEY] = $key;
    # start at the previous line...
    $self->[SELF_HIST_INDEX]-- if $self->[SELF_HIST_INDEX];
    $self->build_search_prompt;
    $self->repaint_input_line;
    $self->rl_set_keymap('isearch');
}

sub rl_capitalize_word {
    my ($self, $key) = @_;
    # Capitalize from cursor on.
    if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*)(\S+)/) {
	# Track leading space, and uppercase word.
	my $space = $1; $space = '' unless defined $space;
	my $word  = ucfirst(lc($2));
	
	# Replace text with the uppercase version.
	substr( $self->[SELF_INPUT],
		$self->[SELF_CURSOR_INPUT] + length($space), length($word)
	      ) = $word;
	
	# Display the new text; move the cursor after it.
	print $stdout $space, normalize($word);
	$self->[SELF_CURSOR_INPUT] += length($space . $word);
	$self->[SELF_CURSOR_DISPLAY] += length($space) + display_width($word);
    } else {
	$self->rl_ding;
    }
}

sub rl_upcase_word {
    my ($self, $key) = @_;
    # Uppercase from cursor on.
    # Modelled after capitalize.
    if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*)(\S+)/) {
	my $space = $1; $space = '' unless defined $space;
	my $word  = uc($2);
	substr( $self->[SELF_INPUT],
		$self->[SELF_CURSOR_INPUT] + length($space), length($word)
	      ) = $word;
	print $stdout $space, normalize($word);
	$self->[SELF_CURSOR_INPUT] += length($space . $word);
	$self->[SELF_CURSOR_DISPLAY] += length($space) + display_width($word);
    } else {
	$self->rl_ding;
    }
}


sub rl_downcase_word {
    my ($self, $key) = @_;
    # Lowercase from cursor on.
    # Modelled after capitalize.
    if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*)(\S+)/) {
	my $space = $1; $space = '' unless defined $space;
	my $word  = lc($2);
	substr( $self->[SELF_INPUT],
		$self->[SELF_CURSOR_INPUT] + length($space), length($word)
	      ) = $word;
	print $stdout $space, normalize($word);
	$self->[SELF_CURSOR_INPUT] += length($space . $word);
	$self->[SELF_CURSOR_DISPLAY] += length($space) + display_width($word);
    } else {
	$self->rl_ding;
    }
    next;
}

sub rl_quoted_insert {
    my ($self, $key) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my ($k,$rk) = @_;
	$self->rl_self_insert($k, $rk);
    }
}

sub rl_overwrite_mode {
    my ($self, $key) = @_;
    $self->[SELF_INSERT_MODE] = !$self->[SELF_INSERT_MODE];
    if ($self->[SELF_COUNT]) {
	if ($self->[SELF_COUNT] > 0) {
	    $self->[SELF_INSERT_MODE] = 0;
	} else {
	    $self->[SELF_INSERT_MODE] = 1;
	}
    }
}
sub rl_vi_replace {
    my ($self) = @_;
    $self->rl_vi_insertion_mode;
    $self->rl_overwrite_mode;
}

sub rl_tilde_expand {
    my ($self) = @_;
    my $pre = substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]);
    my ($append) = (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\w+)/);
    my ($left,$user) = ("$pre$append" =~  /^(.*)~(\S+)$/);
    if ($user) {
	my $dir = (getpwnam($user))[7];
	if (!$dir) {
	    print "\x0D\x0Ausername '$user' not found\x0D\x0A";
	    $self->repaint_input_line;
	    return $self->rl_ding;
	}
	$self->wipe_input_line;
	substr($self->[SELF_INPUT], length($left), length($user) + 1) = $dir; # +1 for tilde
	$self->[SELF_CURSOR_INPUT] += length($dir) - length($user) - 1;
	$self->[SELF_CURSOR_DISPLAY] += length($dir) - length($user) - 1;
	$self->repaint_input_line;
	return 1;
    } else {
	return $self->rl_ding;
    }
}

sub complete_match {
    my ($self) = @_;
    my $lookfor = substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]);
    $lookfor =~ /(\S+)$/;
    $lookfor = $1;
    my $point = $self->[SELF_CURSOR_INPUT] - length($lookfor);

    my @clist = ();
    if ($self->option("completion_function")) {
	my $fn = $self->[SELF_OPTIONS]->{completion_function};
	@clist = &$fn($lookfor, $self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]);
    }
    my @poss = @clist;
    if ($lookfor) {
	my $l = length $lookfor;
	@poss = grep { substr($_, 0, $l) eq $lookfor } @clist;
    }

    return @poss;
}

sub complete_list {
    my ($self, @poss) = @_;
    my $width = 0;
    if ($self->option('print-completions-horizontally') eq 'on') {
	map { $width = (length($_) > $width) ? length($_) : $width } @poss;
	my $cols = int($trk_cols / $width);
	$cols = int($trk_cols / ($width+$cols)); # ensure enough room for spaces
	$width = int($trk_cols / $cols);

	print $stdout "\x0D\x0A";
	my $c = 0;
	foreach my $word (@poss) {
	    print $stdout $word . (" " x ($width - length($word)));
	    if (++$c == $cols) {
		print $stdout "\x0D\x0A";
		$c = 0;
	    }
	}
	print "\x0D\x0A" if $c;
    } else {
	print "\x0D\x0A";
	foreach my $word (@poss) {
	    print $stdout $word . "\x0D\x0A";
	}
    }
    $self->repaint_input_line;
}

sub rl_possible_completions {
    my ($self, $key) = @_;

    my @poss = $self->complete_match;
    if (scalar @poss == 0) {
	return $self->rl_ding;
    }
    $self->complete_list(@poss);
}

sub rl_complete {
    my ($self, $key) = @_;

    my $lookfor = substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]);
    $lookfor =~ /(\S+)$/;
    $lookfor = $1;
    my $point = $self->[SELF_CURSOR_INPUT] - length($lookfor);
    my @poss = $self->complete_match;
    if (scalar @poss == 0) {
	return $self->rl_ding;
    }

    if (scalar @poss == 1) {
	substr($self->[SELF_INPUT], $point, $self->[SELF_CURSOR_INPUT]) = $poss[0];
	my $rest = substr($self->[SELF_INPUT], $point+length($lookfor));
	print $stdout $rest;
	curs_left(length($rest)-length($poss[0]));
	$self->[SELF_CURSOR_INPUT] += length($poss[0])-length($lookfor);
	$self->[SELF_CURSOR_DISPLAY] += length($poss[0])-length($lookfor);
	return 1;
    }

    # so at this point, we have multiple possibilities
    # find out how much more is in common with the possibilities.
    my $max = length($lookfor);
    while (1) {
	my $letter = undef;
	my $ok = 1;
	foreach my $p (@poss) {
	    if ((length $p) < $max) {
		$ok = 0;
		last;
	    }
	    if (!$letter) {
		$letter = substr($p, $max, 1);
		next;
	    }
	    if (substr($p, $max, 1) ne $letter) {
		$ok = 0;
		last;
	    }
	}
	if ($ok) {
	    $max++;
	} else {
	    last;
	}
    }
    if ($max > length($lookfor)) {
	my $partial = substr($poss[0], 0, $max);
	substr($self->[SELF_INPUT], $point, $self->[SELF_CURSOR_INPUT]) = $partial;
	my $rest = substr($self->[SELF_INPUT], $point+length($lookfor));
	print $stdout $rest;
	curs_left(length($rest)-length($partial));
	$self->[SELF_CURSOR_INPUT] += length($partial)-length($lookfor);
	$self->[SELF_CURSOR_DISPLAY] += length($partial)-length($lookfor);
	return $self->rl_ding;
    }

    if ($self->[SELF_LAST] !~ /complete/ && !$self->option('show-all-if-ambiguous')) {
	return $self->rl_ding;
    }
    $self->complete_list(@poss);
    return 0;
}

sub rl_insert_completions {
    my ($self) = @_;
    my @poss = $self->complete_match;
    if (scalar @poss == 0) {
	return $self->rl_ding;
    }
    # need to back up the current text
    my $lookfor = substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]);
    $lookfor =~ /(\S+)$/;
    $lookfor = $1;
    my $point = length($lookfor);
    while ($point--) {
	$self->rl_backward_delete_char;
    }
    my $text = join(" ", @poss);
    $self->rl_self_insert($text, $text);
}

sub rl_ding {
    my ($self) = @_;
    if (!$self->option('bell-style') || $self->option('bell-style') eq 'audible') {
	print $stdout $tc_bell;
    } elsif ($self->option('bell-style') eq 'visible') {
	print $stdout $tc_visual_bell;
    }
    return 0;
}

sub rl_redraw_current_line {
    my ($self) = @_;
    $self->wipe_input_line;
    $self->repaint_input_line;
}

sub rl_poe_wheel_debug {
    my ($self, $key) = @_;
    my $left = display_width(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]));
    my $sp = $self->[SELF_PROMPT];
    $sp =~ s{\\[\[\]]}{}g;
    print( $stdout
	   "\x0D\x0A",
	   "ID=$self->[SELF_UNIQUE_ID] ",
	   "cursor_input($self->[SELF_CURSOR_INPUT]) ",
	   "cursor_display($self->[SELF_CURSOR_DISPLAY]) ",
	   "term_columns($trk_cols)\x0D\x0A",
	   $sp, normalize($self->[SELF_INPUT])
	 );
    curs_left($left) if $left;
}

sub rl_vi_movement_mode {
    my ($self) = @_;
    $self->rl_set_keymap('vi');
    $self->rl_backward_char if ($self->[SELF_INPUT]);
}

sub rl_vi_append_mode {
    my ($self) = @_;
    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	# we can't just call forward-char, coz we don't want bell to ring.
	my $normal = normalize(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1));
	print $stdout $normal;
	$self->[SELF_CURSOR_INPUT]++;
	$self->[SELF_CURSOR_DISPLAY] += length($normal);
    }
    $self->rl_set_keymap('vi-insert');
}

sub rl_vi_append_eol {
    my ($self) = @_;
    $self->rl_end_of_line;
    $self->rl_vi_append_mode;
}

sub rl_vi_insertion_mode {
    my ($self) = @_;
    $self->rl_set_keymap('vi-insert');
}

sub rl_vi_insert_beg {
    my ($self) = @_;
    $self->rl_beginning_of_line;
    $self->rl_vi_insertion_mode;
}

sub rl_vi_editing_mode {
    my ($self) = @_;
    $self->rl_set_keymap('vi');
}

sub rl_emacs_editing_mode {
    my ($self) = @_;
    $self->rl_set_keymap('emacs');
}

sub rl_vi_eof_maybe {
    my ($self, $key) = @_;
    if (length $self->[SELF_INPUT] == 0) {
	print $stdout uc($key), "\x0D\x0A";
	$poe_kernel->select_read($stdin);
	if ($self->[SELF_HAS_TIMER]) {
	    $poe_kernel->delay( $self->[SELF_STATE_IDLE] );
	    $self->[SELF_HAS_TIMER] = 0;
	}
	$poe_kernel->yield( $self->[SELF_EVENT_INPUT], undef, "eot",
			    $self->[SELF_UNIQUE_ID]
			  );
	$self->[SELF_READING_LINE] = 0;
	$self->[SELF_HIST_INDEX] = @{$self->[SELF_HIST_LIST]};
	
	$self->flush_output_buffer;
	return 0;
    } else {
	return $self->rl_ding;
    }
}

sub rl_vi_change_case {
    my ($self) = @_;
    my $char = substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1);
    if ($char lt 'a') {
	substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1) = lc($char);
    } else {
	substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1) = uc($char);
    }
    $self->rl_forward_char;
}

sub rl_vi_prev_word {
    &rl_backward_word;
}

sub rl_vi_next_word {
    my ($self, $key) = @_;
    if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*\S+\s)/) {
	$self->[SELF_CURSOR_INPUT] += length($1);
	my $right = display_width($1);
	print normalize($1);
	$self->[SELF_CURSOR_DISPLAY] += $right;
    } else {
	return $self->rl_ding;
    }
}

sub rl_vi_end_word {
    my ($self, $key) = @_;
    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	$self->rl_forward_char;
	if (substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*\S+)/) {
	    $self->[SELF_CURSOR_INPUT] += length($1)-1;
	    my $right = display_width($1);
	    print normalize($1);
	    $self->[SELF_CURSOR_DISPLAY] += $right-1;
	    curs_left(1);
	}
    } else {
	return $self->rl_ding;
    }
}

sub rl_vi_column {
    my ($self) = @_;
    $self->[SELF_COUNT] ||= 0;
    $self->rl_beginning_of_line;
    while ($self->[SELF_COUNT]--) {
	$self->rl_forward_char;
    }
    $self->[SELF_COUNT] = 0;
}

sub rl_vi_match {
    my ($self) = @_;
    return $self->rl_ding unless $self->[SELF_INPUT];
    # what paren are we after? look forwards down the line for the closest
    my $pos = $self->[SELF_CURSOR_INPUT];
    my $where = substr($self->[SELF_INPUT], $pos);
    my ($adrift) = ($where =~ m/([^\(\)\{\}\[\]]*)/);
    my $paren = substr($where, length($adrift), 1);
    $pos += length($adrift);

    return $self->rl_ding unless $paren;
    my $what_to_do = {
		      '(' => [ ')', 1 ],
		      '{' => [ '}', 1 ],
		      '[' => [ ']', 1 ],
		      ')' => [ '(', -1 ],
		      '}' => [ '{', -1 ],
		      ']' => [ '[', -1 ],
		     }->{$paren};
    my($opp,$dir) = @{$what_to_do};
    my $level = 1;
    while ($level) {
	if ($dir > 0) {
	    return $self->rl_ding if ($pos == length($self->[SELF_INPUT]));
	    $pos++;
	} else {
	    return $self->rl_ding unless $pos;
	    $pos--;
	}
	my $c = substr($self->[SELF_INPUT], $pos, 1);
	if ($c eq $opp) {
	    $level--;
	} elsif ($c eq $paren) {
	    $level++
	}
    }
    $self->[SELF_COUNT] = $pos;
    $self->rl_vi_column;
    return 1;
}

sub rl_vi_first_print {
    my ($self) = @_;
    $self->rl_beginning_of_line;
    substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*)/;
    if (length($1)) {
	$self->[SELF_CURSOR_INPUT] += length($1);
	my $right = display_width($1);
	print normalize($1);
	$self->[SELF_CURSOR_DISPLAY] += $right;
    }
}

sub rl_vi_delete {
    my ($self) = @_;
    if ($self->[SELF_CURSOR_INPUT] < length($self->[SELF_INPUT])) {
	$self->delete_chars($self->[SELF_CURSOR_INPUT], 1);
	if ($self->[SELF_INPUT] && $self->[SELF_CURSOR_INPUT] >= length($self->[SELF_INPUT])) {
	    $self->[SELF_CURSOR_INPUT]--;
	    $self->[SELF_CURSOR_DISPLAY]--;
	    curs_left(1);
	}
    } else {
	return $self->rl_ding;
    }
}

sub rl_vi_put {
    my ($self, $key) = @_;
    my $pos = scalar @{$self->[SELF_KILL_RING]};
    return $self->rl_ding unless ($pos);
    $pos--;
    if ($self->[SELF_INPUT] && $key eq 'p') {
	my $normal = normalize(substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], 1));
	print $stdout $normal;
	$self->[SELF_CURSOR_INPUT]++;
	$self->[SELF_CURSOR_DISPLAY] += length($normal);
    }
    $self->rl_self_insert($self->[SELF_KILL_RING]->[$pos], $self->[SELF_KILL_RING]->[$pos]);
    if ($self->[SELF_CURSOR_INPUT] >= length($self->[SELF_INPUT])) {
	$self->[SELF_CURSOR_INPUT]--;
	$self->[SELF_CURSOR_DISPLAY]--;
	curs_left(1);
    }
}

sub rl_vi_yank_arg {
    my ($self) = @_;
    $self->rl_vi_append_mode;
    if ($self->rl_yank_last_arg) {
	$self->rl_set_keymap('vi-insert');
    } else {
	$self->rl_set_keymap('vi-command');
    }
}

sub rl_vi_end_spec {
    my ($self) = @_;
    $self->[SELF_PENDING] = undef;
    $self->rl_ding;
    $self->rl_set_keymap('vi');
}

sub rl_vi_spec_end_of_line {
    my ($self) = @_;
    $self->rl_set_keymap('vi');
    $self->vi_apply_spec($self->[SELF_CURSOR_INPUT], length($self->[SELF_INPUT]) - $self->[SELF_CURSOR_INPUT]);
}

sub rl_vi_spec_beginning_of_line {
    my ($self) = @_;
    $self->rl_set_keymap('vi');
    $self->vi_apply_spec(0, $self->[SELF_CURSOR_INPUT]);
}

sub rl_vi_spec_first_print {
    my ($self) = @_;
    substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /^(\s*)/;
    my $len = length($1) || 0;
    my $from = $self->[SELF_CURSOR_INPUT];
    if ($from > $len) {
	my $tmp = $from;
	$from = $len;
	$len = $tmp - $from;
    }
    $self->vi_apply_spec($from, $len);
}


sub rl_vi_spec_word {
    my ($self) = @_;

    my $from = $self->[SELF_CURSOR_INPUT];
    my $len  = length($self->[SELF_INPUT]) - $from + 1;
    if (substr($self->[SELF_INPUT], $from) =~ /^(\s*\S+\s)/) {
	my $word = $1;
	$len = length($word);
    }
    $self->rl_set_keymap('vi');
    $self->vi_apply_spec($from, $len);
}

sub rl_character_search {
    my ($self) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my $key = shift;
	return $self->rl_ding unless substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /(.*)$key/;
	$self->[SELF_COUNT] = $self->[SELF_INPUT] + length($1);
	$self->vi_column;
    }
}

sub rl_character_search_backward {
    my ($self) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my $key = shift;
	return $self->rl_ding unless substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]) =~ /$key([^$key])*$/;
	$self->[SELF_COUNT] = $self->[SELF_INPUT] - length($1);
	$self->vi_column;
    }
}

sub rl_vi_spec_forward_char {
    my ($self) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my $key = shift;
	return $self->rl_ding unless substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /(.*)$key/;
	$self->vi_apply_spec($self->[SELF_CURSOR_INPUT], length($1));
    }
}

sub rl_vi_spec_mark {
    my ($self) = @_;

    $self->[SELF_PENDING_FN] = sub {
	my $key = shift;
	return $self->rl_ding unless exists $self->[SELF_MARKLIST]->{$key};
	my $pos = $self->[SELF_CURSOR_INPUT];
	my $len = $self->[SELF_MARKLIST]->{$key} - $self->[SELF_CURSOR_INPUT];
	if ($len < 0) {
	    $pos += $len;
	    $len = -$len;
	}
	$self->vi_apply_spec($pos, $len);
    }
}

sub vi_apply_spec {
    my ($self, $from, $howmany) = @_;
    &{$self->[SELF_PENDING]}($from, $howmany);
    $self->[SELF_PENDING] = undef if ($self->[SELF_COUNT] <= 1);
}

sub rl_vi_yank_to {
    my ($self, $key) = @_;
    $self->[SELF_PENDING] = sub {
	my ($from, $howmany) = @_;
	push(@{$self->[SELF_KILL_RING]}, substr($self->[SELF_INPUT], $from, $howmany));
    };
    if ($key eq 'Y') {
	$self->rl_vi_spec_end_of_line;
    } else {
	$self->rl_set_keymap('vi-specification');
    }
}

sub rl_vi_delete_to {
    my ($self, $key) = @_;
    $self->[SELF_PENDING] = sub {
	my ($from, $howmany) = @_;
	$self->delete_chars($from, $howmany);
	if ($self->[SELF_INPUT] && $self->[SELF_CURSOR_INPUT] >= length($self->[SELF_INPUT])) {
	    $self->[SELF_CURSOR_INPUT]--;
	    $self->[SELF_CURSOR_DISPLAY]--;
	    curs_left(1);
	}
	$self->rl_set_keymap('vi');
    };
    if ($key eq 'D') {
	$self->rl_vi_spec_end_of_line;
    } else {
	$self->rl_set_keymap('vi-specification');
    }
}

sub rl_vi_change_to {
    my ($self, $key) = @_;
    $self->[SELF_PENDING] = sub {
	my ($from, $howmany) = @_;
	$self->delete_chars($from, $howmany);
	$self->rl_set_keymap('vi-insert');
    };
    if ($key eq 'C') {
	$self->rl_vi_spec_end_of_line;
    } else {
	$self->rl_set_keymap('vi-specification');
    }
}

sub rl_vi_arg_digit {
    my ($self, $key) = @_;
    if ($key == '0' && !$self->[SELF_COUNT]) {
	$self->rl_beginning_of_line;
    } else {
	$self->[SELF_COUNT] .= $key;
    }
}

sub rl_vi_tilde_expand {
    my ($self) = @_;
    if ($self->rl_tilde_expand) {
	$self->rl_vi_append_mode;
    }
}

sub rl_vi_complete {
    my ($self) = @_;
    if ($self->rl_complete) {
	$self->rl_set_keymap('vi-insert');
    }
}

sub rl_vi_goto_mark {
    my ($self) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my $key = shift;
	return $self->rl_ding unless exists $self->[SELF_MARKLIST]->{$key};
	$self->[SELF_COUNT] = $self->[SELF_MARKLIST]->{$key};
	$self->rl_vi_column;
    }
}

sub rl_vi_set_mark  {
    my ($self) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my $key = shift;
	return $self->rl_ding unless ($key >= 'a' && $key <= 'z');
	$self->[SELF_MARKLIST]->{$key} = $self->[SELF_CURSOR_INPUT];
    }
}

sub rl_search_abort {
    my ($self) = @_;
    $self->wipe_input_line;
    $self->[SELF_PROMPT] = $self->[SELF_PREV_PROMPT];
    $self->repaint_input_line;
    $self->[SELF_KEYMAP] = $self->[SELF_SEARCH_MAP];
    $self->[SELF_SEARCH_MAP] = undef;
    $self->[SELF_SEARCH] = undef;
}

sub rl_search_finish {
    my ($self, $key, $raw) = @_;
    $self->wipe_input_line;
    $self->[SELF_PROMPT] = $self->[SELF_PREV_PROMPT];
    $self->repaint_input_line;
    $self->[SELF_KEYMAP] = $self->[SELF_SEARCH_MAP];
    $self->[SELF_SEARCH_MAP] = undef;
    $self->[SELF_SEARCH] = undef;
    $self->apply_key($key, $raw);
}

sub rl_search_key {
    my ($self, $key) = @_;
    $self->[SELF_SEARCH] .= $key;
    $self->search(1);
}

sub rl_vi_search_key {
    my ($self, $key) = @_;
    $self->rl_self_insert($key, $key);
}

sub rl_vi_search {
    my ($self, $key) = @_;
    $self->wipe_input_line;
    $self->[SELF_SEARCH_MAP] = $self->[SELF_KEYMAP];
    if ($key eq '/' && $self->[SELF_HIST_INDEX] < scalar @{$self->[SELF_HIST_LIST]}) {
	$self->[SELF_SEARCH_DIR] = -1;
    } else {
	$self->[SELF_SEARCH_DIR] = +1;
    }
    $self->[SELF_SEARCH_KEY] = $key;
    $self->[SELF_INPUT] = $key;
    $self->[SELF_CURSOR_INPUT] = 1;
    $self->[SELF_CURSOR_DISPLAY] = 1;
    $self->repaint_input_line;
    $self->rl_set_keymap('vi-search');
}

sub rl_vi_search_accept {
    my ($self) = @_;
    $self->wipe_input_line;
    $self->[SELF_CURSOR_INPUT] = 0;
    $self->[SELF_CURSOR_DISPLAY] = 0;
    $self->[SELF_INPUT] =~ s{^[/?]}{};
    $self->[SELF_SEARCH] = $self->[SELF_INPUT] if $self->[SELF_INPUT];
    $self->search(0);
    $self->[SELF_KEYMAP] = $self->[SELF_SEARCH_MAP];
    $self->[SELF_SEARCH_MAP] = undef;
}

sub rl_vi_search_again {
    my ($self, $key) = @_;
    return $self->rl_ding unless $self->[SELF_SEARCH];
    $self->[SELF_HIST_INDEX] += $self->[SELF_SEARCH_DIR];
    if ($self->[SELF_HIST_INDEX] < 0) {
	$self->[SELF_HIST_INDEX] = 0;
	return $self->rl_ding;
    } elsif ($self->[SELF_HIST_INDEX] >= scalar @{$self->[SELF_HIST_LIST]}) {
	$self->[SELF_HIST_INDEX] = (scalar @{$self->[SELF_HIST_LIST]}) - 1;
	return $self->rl_ding;
    }
    $self->wipe_input_line;
    $self->search(0);
}

sub rl_isearch_again {
    my ($self, $key) = @_;
    if ($key ne $self->[SELF_SEARCH_KEY]) {
	$self->[SELF_SEARCH_KEY] = $key;
	$self->[SELF_SEARCH_DIR] = -$self->[SELF_SEARCH_DIR];
    }
    $self->[SELF_HIST_INDEX] += $self->[SELF_SEARCH_DIR];
    if ($self->[SELF_HIST_INDEX] < 0) {
	$self->[SELF_HIST_INDEX] = 0;
	return $self->rl_ding;
    } elsif ($self->[SELF_HIST_INDEX] >= scalar @{$self->[SELF_HIST_LIST]}) {
	$self->[SELF_HIST_INDEX] = (scalar @{$self->[SELF_HIST_LIST]}) - 1;
	return $self->rl_ding;
    }
    $self->search(1);
}

sub rl_non_incremental_forward_search_history {
    my ($self) = @_;
    $self->wipe_input_line;
    $self->[SELF_CURSOR_INPUT] = 0;
    $self->[SELF_CURSOR_DISPLAY] = 0;
    $self->[SELF_SEARCH_DIR] = +1;
    $self->[SELF_SEARCH] = substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]);
    $self->search(0);
}

sub rl_non_incremental_reverse_search_history {
    my ($self) = @_;
    $self->[SELF_HIST_INDEX] --;
    if ($self->[SELF_HIST_INDEX] < 0) {
	$self->[SELF_HIST_INDEX] = 0;
	return $self->rl_ding;
    }
    $self->wipe_input_line;
    $self->[SELF_CURSOR_INPUT] = 0;
    $self->[SELF_CURSOR_DISPLAY] = 0;
    $self->[SELF_SEARCH_DIR] = -1;
    $self->[SELF_SEARCH] = substr($self->[SELF_INPUT], 0, $self->[SELF_CURSOR_INPUT]);
    $self->search(0);
}

sub rl_undo {
    my ($self) = @_;
    $self->rl_ding unless scalar @{$self->[SELF_UNDO]};
    my $tuple = pop @{$self->[SELF_UNDO]};
    ($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT], $self->[SELF_CURSOR_DISPLAY]) = @$tuple;
}

sub rl_vi_redo {
    my ($self, $key) = @_;
    return $self->rl_ding unless $self->[SELF_LAST];
    my $fn = $self->[SELF_LAST];
    $self->$fn();
}

sub rl_vi_char_search {
    my ($self, $key) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my ($k,$rk) = @_;
	$rk = "\\" . $rk if ($rk !~ /\w/);
	return $self->rl_ding unless substr($self->[SELF_INPUT], $self->[SELF_CURSOR_INPUT]) =~ /([^$rk]*)$rk/;
	$self->[SELF_COUNT] = $self->[SELF_CURSOR_INPUT] + length($1);
	$self->rl_vi_column;
    }
}

sub rl_vi_change_char {
    my ($self, $key) = @_;
    $self->[SELF_PENDING_FN] = sub {
	my ($k,$rk) = @_;
	$self->rl_delete_char;
	$self->rl_self_insert($k,$rk);
	$self->rl_backward_char;
    }
}

sub rl_vi_subst {
    my ($self, $key) = @_;
    if ($key eq 's') {
	$self->rl_vi_delete;
    } else {
	$self->rl_beginning_of_line;
	$self->rl_kill_line;
    }
    $self->rl_vi_insertion_mode;
}

# ============================================================
# THE KEYMAP CLASS ITSELF
# ============================================================

package POE::Wheel::ReadLine::Keymap;
my %english_to_termcap =
  (
   'up'        => 'ku',
   'down'      => 'kd',
   'left'      => 'kl',
   'right'     => 'kr',
   'insert'    => 'kI',
   'ins'       => 'kI',
   'delete'    => 'kD',
   'del'       => 'kD',
   'home'      => 'kh',
   'end'       => 'kH',
   'backspace' => 'kb',
   'bs'        => 'kb',
  );
my %english_to_key =
  (
   'space'     => ' ',
   'esc'       => '^[',
   'escape'    => '^[',
   'tab'       => '^I',
   'ret'       => '^J',
   'return'    => '^J',
   'newline'   => '^M',
   'lfd'       => '^L',
   'rubout'    => '^?',
  );

sub init {
    my ($proto, %opts) = @_;
    my $class = ref($proto) || $proto;

    my $default = delete $opts{default} or die("no default specified for keymap");
    my $name    = delete $opts{name} or die("no name specified for keymap");
    my $termcap = delete $opts{termcap} or die("no termcap specified for keymap");

    my $self = {
		name => $name,
		default => $default,
		binding => {},
		prefix => {},
		termcap => $termcap,
	       };

    return bless $self, $class;
}

sub decode  {
    my ($self, $seq) = @_;
    if (exists $english_to_termcap{lc($seq)}) {
	my $key = $self->{termcap}->Tputs($english_to_termcap{lc($seq)}, 1);
	$seq = $key;
    } elsif (exists $english_to_key{lc($seq)}) {
	$seq = $english_to_key{lc($seq)};
    }
    return $seq;
}
sub control { return chr(ord(uc($_[0]))-64) };
sub meta    { return "\x1B" . $_[0] };
sub bind_key {
    my ($self, $inseq, $fn) = @_;
    my $seq = $inseq;
    my $macro = undef;
    if (!ref $fn) {
	if ($fn =~ /^["'](.*)['"]$/) {
	    # A macro
	    $macro = $1;
	    $fn = 'insert-macro';
	} else {
	    if (!exists $POE::Wheel::ReadLine::defuns->{$fn}) {
		print "ignoring $inseq, since function '$fn' is not known\r\n";
		next;
	    }
	}
    }

    # Need to parse key sequence into a trivial lookup form.
    if ($seq =~ s{^"(.*)"$}{$1}) {
	$seq =~ s{\\C-(.)}{control($1)}ge;
	$seq =~ s{\\M-(.)}{meta($1)}ge;
	$seq =~ s{\\e}{\x1B}g;
	$seq =~ s{\\\\}{\\}g;
	$seq =~ s{\\"}{"}g;
	$seq =~ s{\\'}{'}g;
    } else {
	my $orig = $seq;
	do {
	    $orig = $seq;
	    $seq =~ s{(\w*)$}{$self->decode($1)}ge;
	    # 'orrible regex, coz we need to work backwards, to allow
	    # for things like C-M-r, or C-xC-x
	    $seq =~ s{C(ontrol)?-(.)([^-]*)$}{control($2).$3}ge;
	    $seq =~ s{M(eta)?-(.)([^-]*)$}{meta($2).$3}ge;
	} while ($seq ne $orig);
    }

    $self->{binding}->{$seq} = $fn if length $seq;
    $self->{macros}->{$seq} = $macro if $macro;
    #print "bound $inseq (" . POE::Wheel::ReadLine::normalize($seq) . ") to $fn in map $self->{name}\r\n";

    if (length($seq) > 1) {
	# XXX: Should store rawkey prefixes, to avoid the ^ problem.
	# requires converting seq into raw, then applying normalize
	# later on for binding. May not need last step if we keep
	# everything as raw.
	# Some keystrokes generate multi-byte sequences.  Record the prefixes
	# for multi-byte sequences so the keystroke builder knows it's in the
	# middle of something.
	while (length($seq) > 1) {
	    chop $seq;
	    $self->{prefix}->{$seq}++;
	}
    }
}

###############################################################################
1;

__END__

=head1 NAME

POE::Wheel::ReadLine - prompted terminal input

=head1 SYNOPSIS

  # Create the wheel.
  $heap->{wheel} = POE::Wheel::ReadLine->new(
    InputEvent => got_input, appname => 'mycli'
  );

  # Trigger the wheel to read a line of input.
  $heap->{wheel}->get( 'Prompt: ' );

  # Add a line to the wheel's input history.
  $heap->{wheel}->addhistory( $input );

  # Input handler.  If $input is defined, then it contains a line of
  # input.  Otherwise $exception contains a word describing some kind
  # of user exception.  Currently these are 'interrupt' and 'cancel'.
  sub got_input_handler {
    my ($heap, $input, $exception) = @_[HEAP, ARG0, ARG1];
    if (defined $input) {
      $heap->{wheel}->addhistory($input);
      $heap->{wheel}->put("\tGot: $input");
      $heap->{wheel}->get('Prompt: '); # get another line
    }
    else {
      $heap->{wheel}->put("\tException: $exception");
    }
  }

  # Clear the terminal.
  $heap->{wheel}->clear();

=head1 DESCRIPTION

ReadLine performs non-blocking, event-driven console input, using
Term::Cap to interact with the terminal display and Term::ReadKey to
interact with its keyboard.

ReadLine handles almost all common input editing keys; it provides an
input history list; it has both vi and emacs modes; it provides
incremental search facilities; it is fully customizable and it is
compatible with standard readline(3) implementations such as
Term::ReadLine::Gnu.

ReadLine is configured by placing commands in an initialization file
(the inputrc file). The name of this file is taken from the value of
the B<INPUTRC> environment variable.  If that variable is unset, the
default is ~/.inputrc.  When the wheel is instantiated, the init file
is read and the key bindings and variables are set.  There are only a
few basic constructs allowed in the readline init file.  Blank lines
are ignored.  Lines beginning with a '#' are comments.  Lines
beginning with a '$' indicate conditional constructs.  Other lines
denote key bindings and variable settings.  Each program using this
library may add its own commands and bindings. For more detail on the
inputrc file, see readline(3).

The default editing mode will be emacs-style, although this can be
configured by setting the 'editing-mode' variable within the
inputrc, or by setting the EDITOR environment variable.

=head1 PUBLIC METHODS

=head2 History List Management

=over 4

=item addhistory LIST_OF_LINES

Adds a list of lines, presumably from previous input, into the
ReadLine wheel's input history.

=item GetHistory

Returns the list of all currently known history lines.

=item WriteHistory FILE

writes the current history to FILENAME, overwriting FILENAME if
necessary.  If FILENAME is false, then write the history list to
~/.history.  Returns true if successful, or false if not.

=item ReadHistory FILE FROM TO

adds the contents of FILENAME to the history list, a line at a time.
If FILENAME is false, then read from ~/.history.  Start reading at
line FROM and end at TO.  If FROM is omitted or zero, start at the
beginning.  If TO is omitted or less than FROM, then read until the
end of the file.  Returns true if successful, or false if not.

=item history_truncate_file FILE LINES

Truncate the number of lines within FILE to be at most that specified
by LINES. FILE defaults to ~/.history. If LINES is not specified,
then the history file is cleared.

=back

=head2 Miscellaneous Methods

=over 4

=item clear

Clears the terminal.

=item terminal_size

Returns what ReadLine thinks are the current dimensions of the
terminal. The retun value is a list of two elements: the number of
columns and number of rows respectively.

=item get PROMPT

Provide a prompt and enable input.  The wheel will display the prompt
and begin paying attention to the console keyboard after this method
is called.  Once a line or an exception is returned, the wheel will
resume its quiescent state wherein it ignores keystrokes.

The quiet period between input events gives a program the opportunity
to change the prompt or process lines before the next one arrives.

=item Attribs

Returns a reference to a hash of options that can be configured
to modify the readline behaviour.

=item bind_key KEY FN

Bind a function to a named key sequence. The key sequence can be in
any of the forms defined within readline(3). The function should
either be a pre-registered name such as 'self-insert', or it should be
a reference to a function. The binding is made in the current
keymap. If you wish to change keymaps, then use the
rl_set_keymap method.

=item add_defun NAME FN

Create a new (global) function definition which may be then bound to a
key.

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

The 'eot' exception means the user pressed C-d (^D) while the input
line was empty.  EOT is the ASCII name for ^D.

Finally, C<ARG2> contains the ReadLine wheel's unique ID.

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

=item appname

Registers an application name which is used to get appl-specific
keybindings from the .inputrc. If not defined, then the default value
is 'poe-readline'. You may use this in a standard inputrc file to
define application specific settings. For example:

  $if poe-readline
  # bind the following sequence in emacs mode
  set keymap emacs
  # display poe debug data
  Control-xP: poe-wheel-debug
  $endif

=back

=head1 CUSTOM BINDINGS

To bind keys to your own functions, the function name has to be
made visible to the wheel before the binding is attempted. To register
a function, use the method POE::Wheel::ReadLine::add_defun:

  POE::Wheel::ReadLine->add_defun('reverse-line', \&reverse_line);

The function will be called with three parameters: a reference to the
wheel object itself, the key sequence in a printable form, and the raw
key sequence. When adding a new defun, an optional third parameter
may be provided which is a key sequence to bind to. This should be in
the same format as that understood by the inputrc parsing.

=head1 CUSTOM COMPLETION

To configure completion, you need to modify the 'completion_function'
value to be a reference to a function. The function should take three
scalar parameters: the word being completed, the entire input text and
the position within the input text of the word. The return result is
expected to be a list of possible matches. An example usage is as follows:

  my $attribs = $wheel->Attribs;
  $attribs->{completion_function} = sub {
    my ($text, $line, $start) = @_;
    return qw(a list of candidates to complete);
  }

This is the only form of completion currently supported.

=head1 IMPLEMENTATION DIFFERENCES

Although modelled after the readline(3) library, there are some areas
which have not been implemented. The only option settings which have
effect in this implementation are: bell-style, editing-mode,
isearch-terminators, comment-begin, print-completions-horizontally,
show-all-if-ambiguous and completion_function.

The function 'tab-insert' is not implemented, nor are tabs displayed
properly.

=head1 SEE ALSO

POE::Wheel, readline(3), Term::ReadKey, Term::Visual.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

POE::Wheel::ReadLine has some known issues:

=head2 Perl 5.8.0 is Broken

Non-blocking input with Term::ReadKey does not work with Perl 5.8.0.
The problem usually appears on Linux systems.  See:
http://rt.cpan.org/Ticket/Display.html?id=4524 and all the tickets
related to it.

If you suspect your system is one where Term::ReadKey fails, you can
run this test program to be sure.  If you can, upgrade Perl to fix it.
If you can't upgrade Perl, consider alternative input methods, such as
Term::Visual.

  #!/usr/bin/perl
  use Term::ReadKey;
  print "Press 'q' to quit this test.\n";
  ReadMode 5; # Turns off controls keys
  while (1) {
    while (not defined ($key = ReadKey(-1))) {
      print "Didn't get a key.  Sleeping 1 second.\015\012";
      sleep (1);
    }
    print "Got key: $key\015\012";
    ($key eq 'q') and last;
  }
  ReadMode 0; # Reset tty mode before exiting
  exit;

=head2 Non-optimal code2

Dissociating the input and display cursors introduced a lot of code.
Much of this code was thrown in hastily, and things can probably be
done with less work.  To do: Apply some thought to what's already been
done.

The screen should update as quickly as possible, especially on slow
systems.  Do little or no calculation during displaying; either put it
all before or after the display.  Do it consistently for each handled
keystroke, so that certain pairs of editing commands don't have extra
perceived latency.

=head2 Unimplemented features

Input editing is not kept on one line.  If it wraps, and a terminal
cannot wrap back through a line division, the cursor will become lost.
This bites, and it's the next against the wall in my bug hunting.

Unicode, or at least European code pages.  I feel real bad about
throwing away native representation of all the 8th-bit-set characters.
I also have no idea how to do this, and I don't have a system to test
this.  Patches are recommended.

=head1 GOTCHAS / FAQ

Q: Why do I lose my ReadLine prompt every time I send output to the
   screen?

A: You probably are using print or printf to write screen output.
   ReadLine doesn't track STDOUT itself, so it doesn't know when to
   refresh the prompt after you do this.  Use ReadLine's put() method
   to write lines to the console.

=head1 AUTHORS & COPYRIGHTS

Rocco Caputo - Original author.
Nick Williams - Heavy edits, making it gnu readline-alike.

Please see L<POE> for more information about other authors and
contributors.

=cut
