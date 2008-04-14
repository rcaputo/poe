# $Id$

package POE::Filter;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use Carp qw(croak);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

# Return all the messages possible to parse in the current input
# buffer.  This uses the newer get_one_start() and get_one(), which is
# implementation dependent.

sub get {
  my ($self, $stream) = @_;
  my @return;

  $self->get_one_start($stream);
  while (1) {
    my $next = $self->get_one();
    last unless @$next;
    push @return, @$next;
  }

  return \@return;
}

sub clone {
  my $self = shift;
  my $buf = (ref($self->[0]) eq 'ARRAY') ? [ ] : '';
  my $nself = bless [
    $buf,                     # BUFFER
    @$self[1..$#$self],  # everything else
  ], ref $self;
  return $nself;
}

#------------------------------------------------------------------------------
1;

__END__

=head1 NAME

POE::Filter - protocol abstractions for POE::Wheel and standalone use

=head1 SYNOPSIS

To use with POE::Wheel classes, pass a POE::Filter object to one of
the /.*Filter$/ constructor parameters.  The following is not a fully
functional program:

TODO - Test

  # Throw a "got_line" event for every line arriving on $socket.
  $_[HEAP]{readwrite} = POE::Wheel::ReadWrite->new(
    Handle => $socket,
    Filter => POE::Filter::Line->new(),
    InputEvent => "got_line",
  );

Standalone use without POE:

TODO - Test

  #!perl

  use warnings;
  use strict;

  my $filter = POE::Filter::Line->new( Literal => "\n" );

  # Prints three lines: one, two three.
  $filter->get_one_start(["one\ntwo\nthr", "ee\nfour"]);
  while (1) {
    my $line = $filter->get_one();
    last unless @$line;
    print $line->[0], "\n";
  }

  # Prints two lines: four, five.
  $filter->get_one_start(["\nfive\n"]);
  while (1) {
    my $line = $filter->get_one();
    last unless @$line;
    print $line->[0], "\n";
  }

=head1 DESCRIPTION

-><- AM HERE

POE::Filter objects plug into the wheels and define how the data will
be serialized for writing and parsed after reading.  POE::Wheel
objects are responsible for moving data, and POE::Filter objects
define how the data should look.

POE::Filter objects are simple by design.  They do not use
higher-level POE features, so they are limited to serialization and
parsing.  This may complicate the implementation of certain protocols
(such as HTTP 1.x), but it allows filters to be used in stand-alone
programs.

Stand-alone use is very important.  It allows application developers
to create lightweight blocking libraries that may be used as simple
clients for POE servers.  POE::Component::IKC::ClientLite is a notable
example.  This lightweight, blocking inter-kernel communication client
supports thin clients for gridded POE applications.  The canonical use
case is to inject events into an IKC grid from CGI applications, which
require lightweight resource use.

POE filters and drivers pass data in array references.  This is
slightly awkward, but it minimizes the amount of data that must be
copied on Perl's stack.

=head1 PUBLIC INTERFACE

All POE::Filter classes must support the minimal interface, defined
here.  Specific filters may implement and document additional methods.

=head2 new PARAMETERS

new() creates and initializes a new filter.  Constructor parameters
vary from one POE::Filter subclass to the next, so please consult the
documentation for your desired filter.

=head2 clone

clone() creates and initializes a new filter based on the constructor
parameters of the existing one.  The new filter is a near-identical
copy, except that its buffers are empty.

Certain components, such as POE::Component::Server::TCP, use clone().
These components accept a master or template filter at creation time,
then clone() that filter for each new connection.

  my $new_filter = $old_filter->clone();

=head2 get_one_start ARRAYREF

get_one_start() accepts an array reference containing unprocessed
stream chunks.  The chunks are added to the filter's internal buffer
for parsing by get_one().

The SYNOPSIS shows get_one_start() in use.

=head2 get_one

get_one() parses zero or one complete record from the filter's
internal buffer.  The data is returned as an ARRAYREF suitable for
passing to another filter or a POE::Wheel object.

get_one() is the lazy form of get().  It only parses only one record
at a time from the filter's buffer.

The SYNOPSIS shows get_one() in use.

=head2 get ARRAYREF

get() is the greedy form of get_one().  It accpets an array reference
containing unprocessed stream chunks, and it adds that data to the
filter's internal buffer.  It then parses as many full records as
possible from the buffer and returns them in another array reference.
Any unprocessed data remains in the filter's buffer for the next call.

In fact, get() is implemented in POE::Filter in terms of
get_one_start() and get_one().

Here's the get() form of the SYNOPSIS stand-alone example:

  my $filter = POE::Filter::Line->new( Literal => "\n" );

  # Prints three lines: one, two three.
  my $lines = $filter->get(["one\ntwo\nthr", "ee\nfour"]);
  foreach my $line (@$lines) {
    print "$line\n";
  }

  # Prints two lines: four, five.
  $lines = $filter->get(["\nfive\n"]);
  foreach my $line (@$lines) {
    print "$line\n";
  }

get() should not be used with wheels that support filter switching.
Its greedy nature means that it often parses streams well in advance
of a wheel's events.  By the time an application changes the wheel's
filter, too much data may have been interpreted already.

Consider a stream of letters, numbers, and periods.  The periods
signal when to switch filters from one that parses letters to one that
parses numbers.

In our hypothetical application, letters must be parsed one at a time,
but numbers may be parsed in a chunk.  We'll use a hypothetical
POE::Filter::Character to parse letters and POE::Filter::Line to parse
numbers.

Here's the sample stream:

  abcdefg.1234567.hijklmnop.890.q

We'll start with a ReadWrite wheel configured to parse input by
character:

  $_[HEAP]{wheel} = POE::Wheel::ReadWrite->new(
    Filter => POE::Filter::Characters->new(),
    Handle => $socket,
    InputEvent => "got_letter",
  );

The "got_letter" handler will be called 8 times.  One for each letter
from a through g, and once for the period following g.  Upon receiving
the period, it will switch the wheel into number mode.

  sub handle_letter {
    my $letter = $_[ARG0];
    if ($letter eq ".") {
      $_[HEAP]{wheel}->set_filter(
        POE::Filter::Line->new( Literal => "." )
      );
      $_[HEAP]{wheel}->event( InputEvent => "got_number" );
    }
    else {
      print "Got letter: $letter\n";
    }
  }

If the greedy get() were used, the entire input stream would have been
parsed as characters in advance of the first handle_letter() call.
The set_filter() call would have been moot, since there would be no
unparsed input data remaining.

The "got_number" handler receives contiguous runs of digits as
period-terminated lines.  The greedy get() would cause a similar
problem as above.

  sub handle_numbers {
    my $numbers = $_[ARG0];
    print "Got number(s): $numbers\n";
    $_[HEAP]->{wheel}->set_filter( POE::Filter::Character->new() );
    $_[HEAP]->{wheel}->event( InputEvent => "got_letter" );
  }

So don't do it!

=head2 put ARRAYREF

put() serializes records into a form that may be written to a file or
sent across a socket.  It accepts a reference to a list of records,
and it returns a reference to a list of marshalled stream chunks.  The
number of output chunks is not necessarily related to the number of
input records.

The list reference it returns may be passed directly to a driver.

  $driver->put( $filter->put( \@records ) );

Or put() may be used to serialize data for other calls.

  my $line_filter = POE::Filter::Line->new();
  my $lines = $line_filter->put(\@list_of_things);
  foreach my $line (@$lines) {
    print $line;
  }

=head2 get_pending

get_pending() returns any data in a filter's input buffer.  The
filter's input buffer is not cleared, however.  get_pending() returns
a list reference if there's any data, or undef if the filter was
empty.

POE::Wheel objects use get_pending() during filter switching.
Unprocessed data is fetched from the old filter with get_pending() and
injected into the new filter with get_one_start().

Filters don't have output buffers, so there's no corresponding "put"
buffer accessor.

=head1 SEE ALSO

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

POE is bundled with the following filters:

L<POE::Filter::Block>
L<POE::Filter::Grep>
L<POE::Filter::HTTPD>
L<POE::Filter::Line>
L<POE::Filter::Map>
L<POE::Filter::RecordBlock>
L<POE::Filter::Reference>
L<POE::Filter::Stackable>
L<POE::Filter::Stream>

=head1 BUGS

In theory, filters should be interchangeable.  In practice, stream and
block protocols tend to be incompatible.

TODO - The examples are untested.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
