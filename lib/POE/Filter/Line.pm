# $Id$

package POE::Filter::Line;

use strict;
use Carp;

sub DEBUG () { 0 }

sub FRAMING_BUFFER () { 0 }
sub INPUT_REGEXP   () { 1 }
sub OUTPUT_LITERAL () { 2 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;

  croak "$type requires an even number of parameters" if @_ and @_ & 1;
  my %params = @_;

  croak "$type cannot have both Regexp and Literal line endings"
    if exists $params{Regexp} and exists $params{Literal};

  my ($input_regexp, $output_literal);

  # Literal newline for both incoming and outgoing.  Every other known
  # parameter conflicts with this one.
  if (exists $params{Literal}) {
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
      $input_regexp = quotemeta $params{InputLiteral};
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
  if (keys %params) {
    carp "$type ignores unknown parameters: ", join(', ', sort keys %params);
  }

  my $self =
    bless [ '',              # FRAMING_BUFFER
            $input_regexp,   # INPUT_REGEXP
            $output_literal, # OUTPUT_LITERAL
          ], $type;

  DEBUG and warn join ':', @$self;

  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;

  $self->[FRAMING_BUFFER] .= join '', @$stream;

  my @lines;
  while ($self->[FRAMING_BUFFER] =~ s/^(.*?)$self->[INPUT_REGEXP]//) {
    push @lines, $1;
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
  return $framing_buffer;
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
