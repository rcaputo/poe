# $Id$

# Filter::HTTPD Copyright 1998 Artur Bergman <artur@vogon.se>.

# Thanks go to Gisle Aas for his excellent HTTP::Daemon.  Some of the
# get code was copied out if, unfournatly HTTP::Daemon is not easily
# subclassed for POE because of the blocking nature.

# 2001-07-27 RCC: This filter will not support the newer get_one()
# interface.  It gets single things by default, and it does not
# support filter switching.  If someone absolutely needs to switch to
# and from HTTPD filters, they should say so on POE's mailing list.

package POE::Filter::HTTPD;
use POE::Preprocessor ( isa => "POE::Macro::UseBytes" );

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(croak);
use HTTP::Status;
use HTTP::Request;
use HTTP::Date qw(time2str);
use URI;

my $HTTP_1_0 = _http_version("HTTP/1.0");
my $HTTP_1_1 = _http_version("HTTP/1.1");

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = { type   => 0,
	       buffer => '',
               finish => 0,
	     };
  bless $self, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;

  {% use_bytes %}

  local($_);

  # Sanity check.  "finish" is set when a request has completely
  # arrived.  Subsequent get() calls on the same request should not
  # happen.  -><- Maybe this should return [] instead of dying?

  if($self->{finish}) {

    # This works around a request length vs. actual content length
    # error.  Looks like some browsers (mozilla!) sometimes add on an
    # extra newline?

    # return [] unless @$stream and grep /\S/, @$stream;

    my (@dump, $offset);
    $stream = join("", @$stream);
    while (length $stream) {
      my $line = substr($stream, 0, 16);
      substr($stream, 0, 16) = '';

      my $hexdump  = unpack 'H*', $line;
      $hexdump =~ s/(..)/$1 /g;

      $line =~ tr[ -~][.]c;
      push @dump, sprintf( "%04x %-47.47s - %s\n", $offset, $hexdump, $line );
      $offset += 16;
    }

    return [ $self->build_error
             ( RC_BAD_REQUEST,
               "Did not want any more data.  Got this:" .
               "<p><pre>" . join("", @dump) . "</pre></p>"
             )
           ];
  }

  # Accumulate data in a framing buffer.

  $self->{buffer} .= join('', @$stream);

  # If headers were already received, then the framing buffer is
  # purely content.  Return nothing until content-length bytes are in
  # the buffer, then return the entire request.

  if($self->{header}) {
    my $buf = $self->{buffer};
    my $r   = $self->{header};
    my $cl  = $r->content_length() || "0 (implicit)";
    if (length($buf) >= $cl) {
      $r->content($buf);
      $self->{finish}++;
      return [$r];
    } else {
      # print "$cl wanted, got " . length($buf) . "\n";
    }
    return [];
  }

  # Headers aren't already received.  Short-circuit header parsing:
  # don't return anything until we've received a blank line.

  return []
    unless($self->{buffer} =~/(\x0D\x0A?\x0D\x0A?|\x0A\x0D?\x0A\x0D?)/s);

  # Copy the buffer for header parsing, and remove the header block
  # from the content buffer.

  my $buf = $self->{buffer};
  $self->{buffer} =~s/.*?(\x0D\x0A?\x0D\x0A?|\x0A\x0D?\x0A\x0D?)//s;

  # Parse the request line.

  if ($buf !~ s/^(\w+)[ \t]+(\S+)(?:[ \t]+(HTTP\/\d+\.\d+))?[^\012]*\012//) {
    return [ $self->build_error(RC_BAD_REQUEST) ];
  }
  my $proto = $3 || "HTTP/0.9";

  # Use the request line to create a request object.

  my $r = HTTP::Request->new($1, URI->new($2));
  $r->protocol($proto);
  $self->{'httpd_client_proto'} = $proto = _http_version($proto);

  # Add the raw request's headers to the request object we'll be
  # returning.

  if($proto >= $HTTP_1_0) {
    my ($key,$val);
  HEADER:
    while ($buf =~ s/^([^\012]*)\012//) {
      $_ = $1;
      s/\015$//;
      if (/^([\w\-]+)\s*:\s*(.*)/) {
	$r->push_header($key, $val) if $key;
	($key, $val) = ($1, $2);
      } elsif (/^\s+(.*)/) {
	$val .= " $1";
      } else {
	last HEADER;
      }
    }
    $r->push_header($key,$val) if($key);
  }

  $self->{header} = $r;

  # If this is a GET or HEAD request, we won't be expecting a message
  # body.  Finish up.

  my $method = $r->method();
  if ($method eq 'GET' or $method eq 'HEAD') {
    $self->{finish}++;
    return [$r];
  }

  # However, if it's a POST request, check whether the entire content
  # has already been received!  If so, add that to the request and
  # we're done.  Otherwise we'll expect a subsequent get() call to
  # finish things up.

  if($method eq 'POST') {

#    print "post:$buf:\END BUFFER\n";
#    print length($buf)."-".$r->content_length()."\n";

    my $cl = $r->content_length();
    return [ $self->build_error(RC_LENGTH_REQUIRED) ] unless defined $cl;
    return [ $self->build_error(RC_BAD_REQUEST    ) ] unless $cl =~ /^\d+$/;
    if (length($buf) >= $cl) {
      $r->content($buf);
      $self->{finish}++;
      return [$r];
    }
  }

  return [];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $responses) = @_;
  my @raw;

  # HTTP::Response's as_string method returns the header lines
  # terminated by "\n", which does not do the right thing if we want
  # to send it to a client.  Here I've stolen HTTP::Response's
  # as_string's code and altered it to use network newlines so picky
  # browsers like lynx get what they expect.

  foreach (@$responses) {
    my $code           = $_->code;
    my $status_message = status_message($code) || "Unknown Error";
    my $message        = $_->message  || "";
    my $proto          = $_->protocol || 'HTTP/1.0';

    my $status_line = "$proto $code";
    $status_line   .= " ($status_message)"  if $status_message ne $message;
    $status_line   .= " $message";

    # Use network newlines, and be sure not to mangle newlines in the
    # response's content.

    my @headers;
    push @headers, $status_line;
    push @headers, $_->headers_as_string("\x0D\x0A");

    push @raw, join("\x0D\x0A", @headers, "") . $_->content;
  }

  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  croak ref($self)." does not support the get_pending() method\n";
  return;
}

#------------------------------------------------------------------------------
# function specific to HTTPD;
#------------------------------------------------------------------------------

# Internal function to parse an HTTP status line and return the HTTP
# protocol version.

sub _http_version {
  local($_) = shift;
  return 0 unless m,^(?:HTTP/)?(\d+)\.(\d+)$,i;
  $1 * 1000 + $2;
}

# Build a basic response, given a status, a content type, and some
# content.

sub build_basic_response {
  my ($self, $content, $content_type, $status) = @_;

  {% use_bytes %}

  $content_type ||= 'text/html';
  $status       ||= RC_OK;

  my $response = HTTP::Response->new($status);

  $response->push_header( 'Content-Type', $content_type );
  $response->push_header( 'Content-Length', length($content) );
  $response->content($content);

  return $response;
}

sub build_error {
  my($self, $status, $details) = @_;

  $status  ||= RC_BAD_REQUEST;
  $details ||= '';
  my $message = status_message($status) || "Unknown Error";

  return
    $self->build_basic_response
      ( ( "<html>" .
          "<head>" .
          "<title>Error $status: $message</title>" .
          "</head>" .
          "<body>" .
          "<h1>Error $status: $message</h1>" .
          "<p>$details</p>" .
          "</body>" .
          "</html>"
        ),
        "text/html",
        $status
      );
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::HTTPD - convert stream to HTTP::Request; HTTP::Response to stream

=head1 SYNOPSIS

  $httpd = POE::Filter::HTTPD->new();
  $arrayref_with_http_response_as_string =
    $httpd->put($full_http_response_object);
  $arrayref_with_http_request_object =
    $line->get($arrayref_of_raw_data_chunks_from_driver);

=head1 DESCRIPTION

The HTTPD filter parses the first HTTP 1.0 request from an incoming
stream into an HTTP::Request object (if the request is good) or an
HTTP::Response object (if the request was malformed).  To send a
response, give its put() method a HTTP::Response object.

Here is a sample input handler:

  sub got_request {
    my ($heap, $request) = @_[HEAP, ARG0];

    # The Filter::HTTPD generated a response instead of a request.
    # There must have been some kind of error.  You could also check
    # (ref($request) eq 'HTTP::Response').
    if ($request->isa('HTTP::Response')) {
      $heap->{wheel}->put($request);
      return;
    }

    # Process the request here.
    my $response = HTTP::Response->new(200);
    $response->push_header( 'Content-Type', 'text/html' );
    $response->content( $request->as_string() );

    $heap->{wheel}->put($response);
  }

Please see the documentation for HTTP::Request and HTTP::Response.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 Streaming Media

It is perfectly possible to use Filter::HTTPD for streaming output
media.  Even if it's not possible to change the input filter from
Filter::HTTPD, by setting the output_filter to Filter::Stream and
omitting any content in the HTTP::Response object.

  $wheel->put($response); # Without content, it sends just headers.
  $wheel->set_output_filter(POE::Filter::Stream->new());
  $wheel->put("Raw content.");

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Keep-alive is not supported.

=head1 AUTHORS & COPYRIGHTS

The HTTPD filter was contributed by Artur Bergman.

Please see L<POE> for more information about authors and contributors.

=cut
