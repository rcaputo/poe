# $Id$

package POE::Filter::Line;

use strict;

use vars qw($VERSION @ISA);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};
@ISA = qw(POE::Filter);

use Carp qw(carp croak);

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

  croak "$type cannot have both Regexp and Literal line endings" if (
    defined $params{Regexp} and defined $params{Literal}
  );

  my ($input_regexp, $output_literal);
  my $autodetect = AUTO_STATE_DONE;

  # Literal newline for both incoming and outgoing.  Every other known
  # parameter conflicts with this one.
  if (defined $params{Literal}) {
    croak "A defined Literal must have a nonzero length"
      unless defined($params{Literal}) and length($params{Literal});
    $input_regexp   = quotemeta $params{Literal};
    $output_literal = $params{Literal};
    if (
      exists $params{InputLiteral} or # undef means something
      defined $params{InputRegexp} or
      defined $params{OutputLiteral}
    ) {
      croak "$type cannot have Literal with any other parameter";
    }
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
        if defined $params{InputRegexp};
    }
    elsif (defined $params{InputRegexp}) {
      $input_regexp = $params{InputRegexp};
      croak "$type cannot have both InputLiteral and InputRegexp"
        if defined $params{InputLiteral};
    }
    else {
      $input_regexp = "(\\x0D\\x0A?|\\x0A\\x0D?)";
    }

    if (defined $params{OutputLiteral}) {
      $output_literal = $params{OutputLiteral};
    }
    else {
      $output_literal = "\x0D\x0A";
    }
  }

  delete @params{qw(Literal InputLiteral OutputLiteral InputRegexp)};
  carp("$type ignores unknown parameters: ", join(', ', sort keys %params))
    if scalar keys %params;

  my $self = bless [
    '',              # FRAMING_BUFFER
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
  LINE: while (1) {

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
      if (
        substr($self->[FRAMING_BUFFER], 0, 1) eq
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
# 2001-07-27 RCC: Add get_one_start() and get_one() to correct filter
# changing and make input flow control possible.

sub get_one_start {
  my ($self, $stream) = @_;

  DEBUG and do {
    my $temp = join '', @$stream;
    $temp = unpack 'H*', $temp;
    warn "got some raw data: $temp\n";
  };

  $self->[FRAMING_BUFFER] .= join '', @$stream;
}

# -><- There is a lot of code duplicated here.  What can be done?

sub get_one {
  my $self = shift;

  # Process as many newlines an we can find.
  LINE: while (1) {

    # Autodetect is done, or it never started.  Parse some buffer!
    unless ($self->[AUTODETECT_STATE]) {
      DEBUG and warn unpack 'H*', $self->[INPUT_REGEXP];
      last LINE
        unless $self->[FRAMING_BUFFER] =~ s/^(.*?)$self->[INPUT_REGEXP]//s;
      DEBUG and warn "got line: <<", unpack('H*', $1), ">>\n";

      return [ $1 ];
    }

    # Waiting for the first line ending.  Look for a generic newline.
    if ($self->[AUTODETECT_STATE] & AUTO_STATE_FIRST) {
      last LINE
        unless $self->[FRAMING_BUFFER] =~ s/^(.*?)(\x0D\x0A?|\x0A\x0D?)//;

      my $line = $1;

      # The newline can be complete under two conditions.  First: If
      # it's two characters.  Second: If there's more data in the
      # framing buffer.  Loop around in case there are more lines.
      if ( (length($2) == 2) or
           (length $self->[FRAMING_BUFFER])
         ) {
        DEBUG and warn "detected complete newline after line: <<$1>>\n";
        $self->[INPUT_REGEXP] = $2;
        $self->[AUTODETECT_STATE] = AUTO_STATE_DONE;
      }

      # The regexp has matched a potential partial newline.  Save it,
      # and move to the next state.  There is no more data in the
      # framing buffer, so we're done.
      else {
        DEBUG and warn "detected suspicious newline after line: <<$1>>\n";
        $self->[INPUT_REGEXP] = $2;
        $self->[AUTODETECT_STATE] = AUTO_STATE_SECOND;
      }

      return [ $line ];
    }

    # Waiting for the second line beginning.  Bail out if we don't
    # have anything in the framing buffer.
    if ($self->[AUTODETECT_STATE] & AUTO_STATE_SECOND) {
      return [ ] unless length $self->[FRAMING_BUFFER];

      # Test the first character to see if it completes the previous
      # potentially partial newline.
      if (
        substr($self->[FRAMING_BUFFER], 0, 1) eq
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

  return [ ];
}

#------------------------------------------------------------------------------
# New behavior.  First translate system newlines ("\n") into whichever
# newlines are supposed to be sent.  Second, add a trailing newline if
# one doesn't already exist.  Since the referenced output list is
# supposed to contain one line per element, we also do a split and
# join.  Bleah. ... why isn't the code doing what the comment says?

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
  return [ $self->[FRAMING_BUFFER] ] if length $self->[FRAMING_BUFFER];
  return undef;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Line - filter data as lines

=head1 SYNOPSIS

  $filter = POE::Filter::Line->new();
  $arrayref_of_lines =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_lines);
  $arrayref_of_leftovers =
    $filter->get_pending();

  # Use a literal newline terminator for input and output:
  $filter = POE::Filter::Line->new( Literal => "\x0D\x0A" );

  # Terminate input lines with a string regexp:
  $filter = POE::Filter::Line->new( InputRegexp   => '[!:]',
                                    OutputLiteral => "!"
                                  );

  # Terminate input lines with a compiled regexp (requires perl 5.005
  # or newer):
  $filter = POE::Filter::Line->new( InputRegexp   => qr/[!:]/,
                                    OutputLiteral => "!"
                                  );

  # Autodetect the input line terminator:
  $filter = POE::Filter::Line->new( InputLiteral => undef );

=head1 DESCRIPTION

The Line filter translates streams to and from separated lines.  The
lines it returns do not include the line separator (usually newlines).
Neither should the lines given to it.

Incoming newlines are recognized with a simple regular expression by
default: C</(\x0D\x0A?|\x0A\x0D?)/>.  This regexp encompasses all the
variations of CR and/or LF, but it has a race condition.

Consider a CRLF newline is broken into two stream chunks, one which
ends with CR and the other which begins with LF:

   some stream dataCR
   LFother stream data

The default regexp will recognize the CR as one end-of-line marker and
the LF as another.  The line filter will emit two lines: "some stream
data" and a blank line.  B<People are advised to specify custom
literal newlines or autodetect the newline style in applications where
blank lines are significant.>

Outgoing lines have traditional network newlines (CRLF) appended to
them by default.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

The default input newline regexp has a race condition where incomplete
newlines can generate spurious blank input lines.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
