# $Id$

package POE::Filter::Line;

use strict;
use Carp;

sub DEBUG () { 0 }

sub FRAMING_BUFFER   () { 0 }
sub INPUT_REGEXP     () { 1 }
sub OUTPUT_LITERAL   () { 2 }
sub AUTODETECT_STATE () { 3 }

sub AUTO_STATE_DONE   () { 0x00 }
sub AUTO_STATE_FIRST  () { 0x01 }
sub AUTO_STATE_SECOND () { 0x02 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;

  croak "$type requires an even number of parameters" if @_ and @_ & 1;
  my %params = @_;

  croak "$type cannot have both Regexp and Literal line endings"
    if exists $params{Regexp} and exists $params{Literal};

  my ($input_regexp, $output_literal);
  my $autodetect = AUTO_STATE_DONE;

  # Literal newline for both incoming and outgoing.  Every other known
  # parameter conflicts with this one.
  if (exists $params{Literal}) {
    croak "Literal must be defined and have a nonzero length"
      unless defined($params{Literal}) and length($params{Literal});
    $input_regexp   = quotemeta $params{Literal};
    $output_literal = $params{Literal};
    croak "$type cannot have Literal with any other parameter"
      if ( exists $params{InputLiteral } or
           exists $params{InputRegexp  } or
           exists $params{OutputLiteral}
         );
  }

  # Input and output are specified separately, then.
  else {

    # Input can be either a literal or a regexp.  The regexp may be
    # compiled or not; we don't rightly care at this point.
    if (exists $params{InputLiteral}) {
      $input_regexp = $params{InputLiteral};

      # InputLiteral is defined.  Turn it into a regexp and be done.
      # Otherwise we will autodetect it.
      if (defined($input_regexp) and length($input_regexp)) {
        $input_regexp = quotemeta $input_regexp;
      }
      else {
        $autodetect   = AUTO_STATE_FIRST;
        $input_regexp = '';
      }

      croak "$type cannot have both InputLiteral and InputRegexp"
        if exists $params{InputRegexp};
    }
    elsif (exists $params{InputRegexp}) {
      $input_regexp = $params{InputRegexp};
      croak "$type cannot have both InputLiteral and InputRegexp"
        if exists $params{InputLiteral};
    }
    else {
      $input_regexp = "(\\x0D\\x0A?|\\x0A\\x0D?)";
    }

    if (exists $params{OutputLiteral}) {
      $output_literal = $params{OutputLiteral};
    }
    else {
      $output_literal = "\x0D\x0A";
    }
  }

  delete @params{qw(Literal InputLiteral OutputLiteral InputRegexp)};
  carp("$type ignores unknown parameters: ", join(', ', sort keys %params))
    if scalar keys %params;

  my $self =
    bless [ '',              # FRAMING_BUFFER
            $input_regexp,   # INPUT_REGEXP
            $output_literal, # OUTPUT_LITERAL
            $autodetect,     # AUTODETECT_STATE
          ], $type;

  DEBUG and warn join ':', @$self;

  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my @lines;

  DEBUG and do {
    my $temp = join '', @$stream;
    $temp = unpack 'H*', $temp;
    warn "got some raw data: $temp\n";
  };

  $self->[FRAMING_BUFFER] .= join '', @$stream;

  # Process as many newlines an we can find.
LINE:
  while (1) {

    # Autodetect is done, or it never started.  Parse some buffer!
    unless ($self->[AUTODETECT_STATE]) {
      DEBUG and warn unpack 'H*', $self->[INPUT_REGEXP];
      last LINE
        unless $self->[FRAMING_BUFFER] =~ s/^(.*?)$self->[INPUT_REGEXP]//s;
      DEBUG and warn "got line: <<", unpack('H*', $1), ">>\n";
      push @lines, $1;
      next LINE;
    }

    # Waiting for the first line ending.  Look for a generic newline.
    if ($self->[AUTODETECT_STATE] & AUTO_STATE_FIRST) {
      last LINE
        unless $self->[FRAMING_BUFFER] =~ s/^(.*?)(\x0D\x0A?|\x0A\x0D?)//;
      push @lines, $1;

      # The newline can be complete under two conditions.  First: If
      # it's two characters.  Second: If there's more data in the
      # framing buffer.  Loop around in case there are more lines.
      if ( (length($2) == 2) or
           (length $self->[FRAMING_BUFFER])
         ) {
        DEBUG and warn "detected complete newline after line: <<$1>>\n";
        $self->[INPUT_REGEXP] = $2;
        $self->[AUTODETECT_STATE] = AUTO_STATE_DONE;
        next LINE;
      }

      # The regexp has matched a potential partial newline.  Save it,
      # and move to the next state.  There is no more data in the
      # framing buffer, so we're done.
      DEBUG and warn "detected suspicious newline after line: <<$1>>\n";
      $self->[INPUT_REGEXP] = $2;
      $self->[AUTODETECT_STATE] = AUTO_STATE_SECOND;
      last LINE;
    }

    # Waiting for the second line beginning.  Bail out if we don't
    # have anything in the framing buffer.
    if ($self->[AUTODETECT_STATE] & AUTO_STATE_SECOND) {
      last LINE unless length $self->[FRAMING_BUFFER];

      # Test the first character to see if it completes the previous
      # potentially partial newline.
      if ( substr($self->[FRAMING_BUFFER], 0, 1) eq
           ( $self->[INPUT_REGEXP] eq "\x0D" ? "\x0A" : "\x0D" )
         ) {

        # Combine the first character with the previous newline, and
        # discard the newline from the buffer.  This is two statements
        # for backward compatibility.
        DEBUG and warn "completed newline after line: <<$1>>\n";
        $self->[INPUT_REGEXP] .= substr($self->[FRAMING_BUFFER], 0, 1);
        substr($self->[FRAMING_BUFFER], 0, 1) = '';
      }
      elsif (DEBUG) {
        warn "decided prior suspicious newline is okay\n";
      }

      # Regardless, whatever is in INPUT_REGEXP is now a complete
      # newline.  End autodetection, post-process the found newline,
      # and loop to see if there are other lines in the buffer.
      $self->[INPUT_REGEXP] = $self->[INPUT_REGEXP];
      $self->[AUTODETECT_STATE] = AUTO_STATE_DONE;
      next LINE;
    }

    die "consistency error: AUTODETECT_STATE = $self->[AUTODETECT_STATE]";
  }

  \@lines;
}

#------------------------------------------------------------------------------
# New behavior.  First translate system newlines ("\n") into whichever
# newlines are supposed to be sent.  Second, add a trailing newline if
# one doesn't already exist.  Since the referenced output list is
# supposed to contain one line per element, we also do a split and
# join.  Bleah.

sub put {
  my ($self, $lines) = @_;

  my @raw;
  foreach (@$lines) {
    push @raw, $_ . $self->[OUTPUT_LITERAL];
  }

  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  my $framing_buffer = $self->[FRAMING_BUFFER];
  $self->[FRAMING_BUFFER] = '';
  return [ $framing_buffer ] if length $framing_buffer;
  return undef;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Line - POE Line Protocol Abstraction

=head1 SYNOPSIS

  $filter = POE::Filter::Line->new();
  $arrayref_of_lines =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_lines);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($single_line);
  $arrayref_of_leftovers =
    $filter->get_pending();

  # To use a literal newline terminator for input and output:
  $filter = POE::Filter::Line->new( Literal => "\x0D\x0A" );

  # To terminate input lines with a string regexp:
  $filter = POE::Filter::Line->new( InputRegexp   => '[!:]',
                                    OutputLiteral => "!"
                                  );

  # To terminate input lines with a compiled regexp (requires perl
  # 5.005 or newer):
  $filter = POE::Filter::Line->new( InputRegexp   => qr/[!:]/,
                                    OutputLiteral => "!"
                                  );

  # To autodetect the input line terminator:
  $filter = POE::Filter::Line->new( InputLiteral => undef );

=head1 DESCRIPTION

The Line filter translates streams to and from newline-separated
lines.  The lines it returns do not contain newlines.  Neither should
the lines given to it.

By default, incoming newline are recognized with a regular
subexpression: C</(\x0D\x0A?|\x0A\x0D?)/>.  This encompasses all sorts
of variations on CR and LF, but it has a problem.  If incoming data is
broken between CR and LF, then the second character will be
interpreted as a blank line.  This doesn't happen often, but it can
happen often enough.  B<People are advised to specify custom newlines
in applications where blank lines are significant.>

By default, outgoing lines have traditional network newlines attached
to them: C<"\x0D\x0A">, or CRLF.  The C<OutputLiteral> parameter is
used to specify a new one.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Reference;
POE::Filter::Stream

=head1 BUGS

The default input newline regexp has a race condition where incomplete
newlines can generate spurious blank input lines.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
