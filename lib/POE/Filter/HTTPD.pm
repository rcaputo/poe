# Filter::HTTPD Copyright 1998 Artur Bergman <artur@vogon.se>.
# Thanks go to Gisle Aas for his excellent HTTP::Daemon.  Some of the
# get code was copied out if, unfortunately HTTP::Daemon is not easily
# subclassed for POE because of the blocking nature.
# 2001-07-27 RCC: This filter will not support the newer get_one()
# interface.  It gets single things by default, and it does not
# support filter switching.  If someone absolutely needs to switch to
# and from HTTPD filters, they should submit their request as a patch.

package POE::Filter::HTTPD;

use strict;
use POE::Filter;

use vars qw($VERSION @ISA);
$VERSION = '1.360';
# NOTE - Should be #.### (three decimal places)
@ISA = qw(POE::Filter);

sub DEBUG () { 0 }

sub BUFFER        () { 0 } # raw data buffer to build requests
sub STATE         () { 1 } # built a full request
sub REQUEST       () { 2 } # partial request being built
sub CLIENT_PROTO  () { 3 } # client protocol version requested
sub CONTENT_LEN   () { 4 } # expected content length
sub CONTENT_ADDED () { 5 } # amount of content added to request
sub CONTENT_MAX   () { 6 } # max amount of content
sub STREAMING     () { 7 } # we want to work in streaming mode
sub MAX_BUFFER    () { 8 } # max size of framing buffer
sub FIRST_UNUSED  () { 9 }

sub ST_HEADERS    () { 0x01 } # waiting for complete header block
sub ST_CONTENT    () { 0x02 } # waiting for complete body

use Carp qw(croak);
use HTTP::Status qw( status_message RC_BAD_REQUEST RC_OK RC_LENGTH_REQUIRED 
                                    RC_REQUEST_ENTITY_TOO_LARGE );
use HTTP::Request ();
use HTTP::Response ();
use HTTP::Date qw(time2str);
use URI ();

my $HTTP_1_0 = _http_version("HTTP/1.0");
my $HTTP_1_1 = _http_version("HTTP/1.1");

use base 'Exporter';
our @EXPORT_OK = qw( FIRST_UNUSED );



#------------------------------------------------------------------------------
# Set up some routines for convert wide chars (which aren't allowed in HTTP headers)
# into MIME encoded equivalents.
# See ->headers_as_strings
BEGIN {
    eval "use utf8";
    if( $@ ) {
        DEBUG and warn "We don't have utf8.";
        *HAVE_UTF8 = sub { 0 };
    }
    else {        
        *HAVE_UTF8 = sub { 1 };
        my $downgrade = sub {   
                        my $ret = $_[0];
                        utf8::downgrade( $ret );
                        return $ret 
                    };
        eval "use Email::MIME::RFC2047::Encoder";
        if( $@ ) {
            DEBUG and warn "We don't have Email::MIME::RFC2047::Encoder";
            *encode_value = sub {
              Carp::cluck(
                "Downgrading wide characters in HTTP header. " .
                "Consier installing Email::MIME::RFC2047::Encoder"
              );
              $downgrade->( @_ );
            };
        }
        else {
            my $encoder = Email::MIME::RFC2047::Encoder->new( encoding => 'iso-8859-1', 
                                                              method => 'Q'
                                                            );
            *encode_value = sub { $downgrade->( $encoder->encode_text( @_ ) ) };
        }
    }
}


#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type requires an even number of parameters" if @_ and @_ & 1;
  my %params = @_;

  my $max_content = $type->__param_max( MaxContent => 1024*1024, \%params );
  my $max_buffer = $type->__param_max( MaxBuffer => 512*1024*1024, \%params );
  my $streaming = $params{Streaming} || 0;

  croak "MaxBuffer is not large enough for MaxContent"
        unless $max_buffer >= $max_content + length( $max_content ) + 1;

  delete @params{qw(MaxContent MaxBuffer Streaming)};
  carp("$type ignores unknown parameters: ", join(', ', sort keys %params))
    if scalar keys %params;

  return bless(
    [
      '',         # BUFFER
      ST_HEADERS, # STATE
      undef,      # REQUEST
      undef,      # CLIENT_PROTO
      0,          # CONTENT_LEN
      0,          # CONTENT_ADDED
      $max_content, # CONTENT_MAX
      $streaming, # STREAMING
      $max_buffer # MAX_BUFFER
    ],
    $type
  );
}

#------------------------------------------------------------------------------

sub get_one_start {
  my ($self, $stream) = @_;
    
  $self->[BUFFER] .= join( '', @$stream );
  DEBUG and warn "$$:poe-filter-httpd: Buffered ".length( $self->[BUFFER] )." bytes";
  die "Framing buffer exceeds the limit"
    if $self->[MAX_BUFFER] < length( $self->[BUFFER] );
}

sub get_one {
  my ($self) = @_;

  # Need to check lengths in octets, not characters.
  BEGIN { eval { require bytes } and bytes->import; }

  # Waiting for a complete suite of headers.
  if ($self->[STATE] & ST_HEADERS) {
    DEBUG and warn "$$:poe-filter-httpd: Looking for headers";
    # Strip leading whitespace.
    $self->[BUFFER] =~ s/^\s+//;

    # No blank line yet.  Side effect: Raw headers block is extracted
    # from the input buffer.
    return [] unless (
      $self->[BUFFER] =~
      s/^(\S.*?(?:\x0D\x0A?\x0D\x0A?|\x0A\x0D?\x0A\x0D?))//s
    );

    # Raw headers block from the input buffer.
    my $rh = $1;

    # Parse the request line.
    if ($rh !~ s/^(\w+)[ \t]+(\S+)(?:[ \t]+(HTTP\/\d+\.\d+))?[^\012]*\012//) {
      return [
        $self->_build_error(RC_BAD_REQUEST, "Request line parse failure. ($rh)")
      ];
    }

    # Create an HTTP::Request object from values in the request line.
    my ($method, $request_path, $proto) = ($1, $2, ($3 || "HTTP/0.9"));

    # Fix a double starting slash on the path.  It happens.
    $request_path =~ s!^//+!/!;

    my $r = HTTP::Request->new($method, URI->new($request_path));
    $r->protocol($proto);
    $self->[CLIENT_PROTO] = $proto = _http_version($proto);

    # Parse headers.

    my ($key, $val);
    HEADER: while ($rh =~ s/^([^\012]*)\012//) {
      local $_ = $1;
      s/\015$//;
      if (/^([\w\-~]+)\s*:\s*(.*)/) {
        $r->push_header($key, $val) if $key;
        ($key, $val) = ($1, $2);
      }
      elsif (/^\s+(.*)/) {
        $val .= " $1";
      }
      else {
        last HEADER;
      }
    }

    $r->push_header($key, $val) if $key;

    # We got a full set of headers.  Fall through to content if we
    # have a content length.

    my $cl = $r->content_length();
    if( defined $cl ) {
        unless( $cl =~ /^\s*(\d+)\s*$/ ) {
            $r = $self->_build_error(RC_BAD_REQUEST, 
                                 "Content-Length is not a number.",
                                 $r);
            $self->[BUFFER] = '';
            $self->_reset();
            return [ $r ];
        }
        $cl = $1 || 0;
    }
    my $ce = $r->content_encoding();
    
#   The presence of a message-body in a request is signaled by the
#   inclusion of a Content-Length or Transfer-Encoding header field in
#   the request's message-headers. A message-body MUST NOT be included in
#   a request if the specification of the request method (section 5.1.1)
#   does not allow sending an entity-body in requests. A server SHOULD
#   read and forward a message-body on any request; if the request method
#   does not include defined semantics for an entity-body, then the
#   message-body SHOULD be ignored when handling the request.
#   - RFC2616

    unless( defined $cl || defined $ce ) {
        # warn "No body";
        $self->_reset();
        return [ $r ];
    }
    
    # PG- GET shouldn't have a body. But RFC2616 talks about Content-Length
    # for HEAD.  And My reading of RFC2616 is that HEAD is the same as GET.
    # So logically, GET can have a body.  And RFC2616 says we SHOULD ignore
    # it.
    #
    # What's more, in apache 1.3.28, a body on a GET or HEAD is read
    # and discarded.  See ap_discard_request_body() in http_protocol.c and
    # default_handler() in http_core.c
    #
    # Neither Firefox 2.0 nor Lynx 2.8.5 set Content-Length on a GET

#   For compatibility with HTTP/1.0 applications, HTTP/1.1 requests
#   containing a message-body MUST include a valid Content-Length header
#   field unless the server is known to be HTTP/1.1 compliant. If a
#   request contains a message-body and a Content-Length is not given,
#   the server SHOULD respond with 400 (bad request) if it cannot
#   determine the length of the message, or with 411 (length required) if
#   it wishes to insist on receiving a valid Content-Length.
# - RFC2616 
#
# PG- This seems to imply that we can either detect the length (but how
#     would one do that?) or require a Content-Length header.  We do the
#     latter.
# 
# PG- Dispite all the above, I'm not fully sure this implements RFC2616
#     properly.  There's something about transfer-coding that I don't fully
#     understand.

    if ( not $cl) {         
      # assume a Content-Length of 0 is valid pre 1.1
      if ($self->[CLIENT_PROTO] >= $HTTP_1_1 and not defined $cl) {
        # We have Content-Encoding, but not Content-Length.
        $r = $self->_build_error(RC_LENGTH_REQUIRED, 
                                 "No content length found.",
                                 $r);
      }
      $self->[BUFFER] = '';
      $self->_reset();
      return [ $r ];
    }

    # Prevent DOS of a server by malicious clients
    if( not $self->[STREAMING] and $cl > $self->[CONTENT_MAX] ) {
        $r = $self->_build_error(RC_REQUEST_ENTITY_TOO_LARGE, 
                                 "Content of $cl octets not accepted.",
                                 $r);
        $self->[BUFFER] = '';
        $self->_reset();
        return [ $r ];
    }

    $self->[REQUEST] = $r;
    $self->[CONTENT_LEN] = $cl;
    $self->[STATE] = ST_CONTENT;
    # Fall through to content.
  }

  # Waiting for content.
  if ($self->[STATE] & ST_CONTENT) {
    my $r         = $self->[REQUEST];
    my $cl_needed = $self->[CONTENT_LEN] - $self->[CONTENT_ADDED];
    die "already got enough content ($cl_needed needed)" if $cl_needed < 1;

    if( $self->[STREAMING] ) {
        DEBUG and warn "$$:poe-filter-httpd: Streaming request content";
        my @ret;
        # do we have a request?
        if( $self->[REQUEST] ) {
            DEBUG and warn "$$:poe-filter-httpd: Sending request";
            push @ret, $self->[REQUEST];    # send it to the wheel
            $self->[REQUEST] = undef;
        }
        # do we have some content ?
        if( length( $self->[BUFFER] ) ) {   # send it to the wheel
            my $more = substr($self->[BUFFER], 0, $cl_needed);
            DEBUG and warn "$$:poe-filter-httpd: Sending content";
            push @ret, $more;
            $self->[CONTENT_ADDED] += length($more);
            substr( $self->[BUFFER], 0, length($more) ) = "";
            # is that enough content?
            if( $self->[CONTENT_ADDED] >= $self->[CONTENT_LEN] ) {
                DEBUG and warn "$$:poe-filter-httpd: All content received ($self->[CONTENT_ADDED] >= $self->[CONTENT_LEN])";
                # Strip MSIE 5.01's extra CRLFs
                $self->[BUFFER] =~ s/^\s+//;
                $self->_reset;
            } 
        }
        return \@ret;
    }

    # Not enough content to complete the request.  Add it to the
    # request content, and return an incomplete status.
    if (length($self->[BUFFER]) < $cl_needed) {
      $r->add_content($self->[BUFFER]);
      $self->[CONTENT_ADDED] += length($self->[BUFFER]);
      $self->[BUFFER] = "";
      return [];
    }

    # Enough data.  Add it to the request content.
    # PG- CGI.pm only reads Content-Length: bytes from STDIN.

    # Four-argument substr() would be ideal here, but it's not
    # entirely backward compatible.
    $r->add_content(substr($self->[BUFFER], 0, $cl_needed));
    substr($self->[BUFFER], 0, $cl_needed) = "";

    # Some browsers (like MSIE 5.01) send extra CRLFs after the
    # content.  Shame on them.
    $self->[BUFFER] =~ s/^\s+//;

    # XXX Should we throw the body away on a GET or HEAD? Probably not.

    # XXX Should we parse Multipart Types bodies?

    # Prepare for the next request, and return this one.
    $self->_reset();
    return [ $r ];
  }

  # What are we waiting for?
  die "unknown state $self->[STATE]";
}

# Prepare for next request
sub _reset
{
   my($self) = @_;
   $self->[STATE] = ST_HEADERS;
   @$self[REQUEST, CLIENT_PROTO]       = (undef, undef);
   @$self[CONTENT_LEN, CONTENT_ADDED]  = (0, 0);
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
  # PG- $r->as_string( "\x0D\x0A" ); would accomplish the same thing, no?

  foreach (@$responses) {
    my $code           = $_->code;
    my $status_message = status_message($code) || "Unknown Error";
    my $message        = $_->message  || "";
    my $proto          = $_->protocol || 'HTTP/1.0';

    my $status_line = "$proto $code";
    $status_line   .= " ($status_message)"  if $status_message ne $message;
    $status_line   .= " $message" if length($message);

    # Use network newlines, and be sure not to mangle newlines in the
    # response's content.

    my @headers;
    push @headers, $status_line;

    # Perl can magically promote a string to UTF-8 if it is concatinated
    # with another UTF-8 string.  This behaviour changed between 5.8.8 and
    # 5.10.1.  This is normaly not a problem, but POE::Driver::SysRW uses
    # syswrite(), which sends POE's internal buffer as-is.  
    # In other words, if the header contains UTF-8, the content will be
    # promoted to UTF-8 and syswrite() will send those wide bytes, which
    # will corrupt any images.
    # For instance, 00 e7 ff 00 00 00 05
    # will become,  00 c3 a7 c3 bf 00 00 00 05
    #
    # The real bug is in HTTP::Message->headers_as_string, which doesn't respect
    # the following:
    # 
    # "The TEXT rule is only used for descriptive field contents and values
    #  that are not intended to be interpreted by the message parser.  Words
    #  of *TEXT MAY contain characters from character sets other than ISO-
    #  8859-1 [22] only when encoded according to the rules of RFC 2047
    #  [14]. " -- RFC2616 section 2.2
    # http://www.ietf.org/rfc/rfc2616.txt
    # http://www.ietf.org/rfc/rfc2047.txt
    my $endl = "\x0D\x0A";
    push @headers, $self->headers_as_strings( $_->headers, $endl );
    push @raw, join( $endl, @headers, "", "") . $_->content;
  }

  \@raw;
}

sub headers_as_strings
{
    my( $self, $H, $endl ) = @_;
    my @ret;
    # $H is a HTTP::Headers object
    foreach my $name ( $H->header_field_names ) {
        # message-header = field-name ":" [ field-value ]
        # field-name     = token
        # RFC2616 section 4.2
        #
        # token          = 1*<any CHAR except CTLs or separators>
        # separators     = "(" | ")" | "<" | ">" | "@"
        #                  | "," | ";" | ":" | "\" | <">
        #                  | "/" | "[" | "]" | "?" | "="
        #                  | "{" | "}" | SP | HT
        # CHAR           = <any US-ASCII character (octets 0 - 127)>        
        # CTL            = <any US-ASCII control character
        #                                (octets 0 - 31) and DEL (127)> 
        # SP             = <US-ASCII SP, space (32)> 
        # HT             = <US-ASCII HT, horizontal-tab (9)>
        # RFC2616 section 2.2 

        # In other words, plain ascii text.  HTTP::Headers doesn't check for
        # this, of course.  So if we complain here, the cluck ends up in
        # the wrong place.  Doing the simplest thing
        utf8::downgrade( $name ) if HAVE_UTF8;

        # Deal with header values
        foreach my $value ( $H->header( $name ) ) {
            if( HAVE_UTF8 and utf8::is_utf8( $value ) ) {
                DEBUG and warn "$$: Header $name is UTF-8";
                $value = encode_value( $value );
            }
            
            push @ret, join ": ", $name, _process_newline( $value, $endl );
        }
    }
    return @ret;
}

# This routine is lifted as-is from HTTP::Headers
sub _process_newline {
    local $_ = shift;
    my $endl = shift;
    # must handle header values with embedded newlines with care
    s/\s+$//;        # trailing newlines and space must go
    s/\n(\x0d?\n)+/\n/g;     # no empty lines
    s/\n([^\040\t])/\n $1/g; # initial space for continuation
    s/\n/$endl/g;    # substitute with requested line ending
    $_;
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  return [ $self->[BUFFER] ] if length $self->[BUFFER];
  return undef;
}

#------------------------------------------------------------------------------
# Functions specific to HTTPD;
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

sub _build_basic_response {
  my ($self, $content, $content_type, $status, $message) = @_;

  # Need to check lengths in octets, not characters.
  BEGIN { eval { require bytes } and bytes->import; }

  $content_type ||= 'text/html';
  $status       ||= RC_OK;

  my $response = HTTP::Response->new($status, $message);

  $response->push_header( 'Content-Type', $content_type );
  $response->push_header( 'Content-Length', length($content) );
  $response->content($content);

  return $response;
}

sub _build_error {
  my($self, $status, $details, $req) = @_;

  $status  ||= RC_BAD_REQUEST;
  $details ||= '';
  my $message = status_message($status) || "Unknown Error";

  my $resp = $self->_build_basic_response(
    ( "<html>" .
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
    $status,
    $message
  );
  $resp->request( $req ) if $req;
  return $resp;
}

1;

__END__

=head1 NAME

POE::Filter::HTTPD - parse simple HTTP requests, and serialize HTTP::Response

=head1 SYNOPSIS

  #!perl

  use warnings;
  use strict;

  use POE qw(Component::Server::TCP Filter::HTTPD);
  use HTTP::Response;

  POE::Component::Server::TCP->new(
    Port         => 8088,
    ClientFilter => 'POE::Filter::HTTPD',  ### <-- HERE WE ARE!

    ClientInput => sub {
      my $request = $_[ARG0];

      # It's a response for the client if there was a problem.
      if ($request->isa("HTTP::Response")) {
        my $response = $request;

        $request = $response->request;
        warn "ERROR: ", $request->message if $request;

        $_[HEAP]{client}->put($response);
        $_[KERNEL]->yield("shutdown");
        return;
      }

      my $request_fields = '';
      $request->headers()->scan(
        sub {
          my ($header, $value) = @_;
          $request_fields .= (
            "<tr><td>$header</td><td>$value</td></tr>"
          );
        }
      );

      my $response = HTTP::Response->new(200);
      $response->push_header( 'Content-type', 'text/html' );
      $response->content(
        "<html><head><title>Your Request</title></head>" .
        "<body>Details about your request:" .
        "<table border='1'>$request_fields</table>" .
        "</body></html>"
      );

      $_[HEAP]{client}->put($response);
      $_[KERNEL]->yield("shutdown");
    }
  );

  print "Aim your browser at port 8088 of this host.\n";
  POE::Kernel->run();
  exit;

=head1 DESCRIPTION

POE::Filter::HTTPD interprets input streams as HTTP 0.9, 1.0 or 1.1
requests.  It returns a HTTP::Request objects upon successfully
parsing a request.  

On failure, it returns an HTTP::Response object describing the
failure.  The intention is that application code will notice the
HTTP::Response and send it back without further processing. The
erroneous request object is sometimes available via the
L<HTTP::Response/$r-E<gt>request> method.  This is illustrated in the
L</SYNOPSIS>.

For output, POE::Filter::HTTPD accepts HTTP::Response objects and
returns their corresponding streams.

Please see L<HTTP::Request> and L<HTTP::Response> for details about
how to use these objects.

HTTP headers are not allowed to have UTF-8 characters; they must be
ISO-8859-1.  POE::Filter::HTTPD will convert all UTF-8 into the MIME encoded
equivalent.  It uses L<utf8::is_utf8> for detection-8 and
L<Email::MIME::RFC2047::Encoder> for convertion.  If L<utf8> is not
installed, no conversion happens.  If L<Email::MIME::RFC2047::Encoder> is
not installed, L<utf8::downgrade> is used instead.  In this last case, you will
see a warning if you try to send UTF-8 headers.


=head1 PUBLIC FILTER METHODS

POE::Filter::HTTPD implements the basic POE::Filter interface.

=head2 new

new() accepts a list of named parameters.

C<MaxBuffer> sets the maximum amount of data the filter will hold in memory. 
Defaults to 512 MB (536870912 octets).  Because POE::Filter::HTTPD copies
all data into memory, setting this number to high would allow a malicious
HTTPD client to fill all server memory and swap.

C<MaxContent> sets the maximum size of the content of an HTTP request. 
Defaults to 1 MB (1038336 octets).  Because POE::Filter::HTTPD copies all
data into memory, setting this number to high would allow a malicious HTTPD
client to fill all server memory and swap.  Ignored if L</Streaming> is set.

C<Streaming> turns on request streaming mode.  Defaults to off.  In
streaming mode this filter will return either an HTTP::Request object or a
block of content.  The HTTP::Request object's content will return empty. 
The blocks of content will be parts of the request's body, up to
Content-Length in size.  You distinguish between request objects and content
blocks using C<Scalar::Util/bless> (See L</Streaming request> below).  This
option superceeds L</MaxContent>.

=head1 CAVEATS

Some versions of libwww are known to generate invalid HTTP.  For
example, this code (adapted from the HTTP::Request::Common
documentation) will cause an error in a POE::Filter::HTTPD daemon:

NOTE: Using this test with libwww-perl/5.834 showed that it added
the proper HTTP/1.1 data! We're not sure which version of LWP fixed
this. This example is valid for older LWP installations, beware!

  use HTTP::Request::Common;
  use LWP::UserAgent;

  my $ua = LWP::UserAgent->new();
  $ua->request(POST 'http://example.com', [ foo => 'bar' ]);

By default, HTTP::Request is HTTP version agnostic. It makes no
attempt to add an HTTP version header unless you specifically declare
a protocol using C<< $request->protocol('HTTP/1.0') >>.

According to the HTTP 1.0 RFC (1945), when faced with no HTTP version
header, the parser is to default to HTTP/0.9.  POE::Filter::HTTPD
follows this convention.  In the transaction detailed above, the
Filter::HTTPD based daemon will return a 400 error since POST is not a
valid HTTP/0.9 request type.

Upon handling a request error, it is most expedient and reliable to
respond with the error and shut down the connection.  Invalid HTTP
requests may corrupt the request stream.  For example, the absence of
a Content-Length header signals that a request has no content.
Requests with content but without that header will be broken into a
content-less request and invalid data.  The invalid data may also
appear to be a request!  Hilarity will ensue, possibly repeatedly,
until the filter can find the next valid request.  By shutting down
the connection on the first sign of error, the client can retry its
request with a clean connection and filter.


=head1 Streaming Request

Normally POE::Filter::HTTPD reads the entire request content into memory
before returning the HTTP::Request to your code.  In streaming mode, it will
return the content seprately, as unblessed scalars.  The content may be
split up into blocks of varying sizes, depending on OS and transport
constraints.  Your code can distinguish the request object from the content
blocks using L<Scalar::Util/blessed>.

    use Scalar::Util;
    use POE::Wheel::ReadWrite;
    use POE::Filter:HTTPD;

    $heap->{wheel} = POE::Wheel::ReadWrite->new( 
                        InputEvent => 'http_input',
                        Filter => POE::Filter::HTTPD->new( Streaming => 1 ),
                        # ....
                );

    sub http_input_handler
    {
        my( $heap, $req_or_data ) = @_[ HEAP, ARG0 ];
        if( blessed $req_or_data ) {
            my $request = $req_or_data;
            if( $request->isa( 'HTTP::Response') ) {
                # HTTP error
                $heap->{wheel}->put( $request );
            }
            else {
                # HTTP request
                # ....
            }
        }
        else {
            my $data = $req_or_data;
            # ....
        }
    }

You may trivally create a DoS bug if you hold all content in memory but do
not impose a maximum Content-Length.  An attacker could send
C<Content-Length: 1099511627776> (aka 1 TB) and keep sending data until all
your system's memory and swap is filled.

Content-Length has been sanitized by POE::Filter::HTTPD so checking it is trivial :

    if( $request->headers( 'Content-Length' ) > 1024*1024 ) {
        my $resp = HTTP::Response->new( RC_REQUEST_ENTITY_TOO_LARGE ), 
                                             "So much content!" ) 
        $heap->{wheel}->put( $resp );
        return;
    }
    
If you want to handle large amounts of data, you should save the content to a file 
before processing it.  You still need to check Content-Length or an attacker might
fill up the partition.

    use File::Temp qw(tempfile);

    if( blessed $_[ARG0] ) {
        $heap->{request} = $_[ARG0];
        if( $heap->{request}->method eq 'GET' ) {
            handle_get( $heap );
            delete $heap->{request};
            return;
        }
        my( $fh, $file ) = tempfile( "httpd-XXXXXXXX", TMPDIR=>1 );
        $heap->{content_file} = $file;
        $heap->{content_fh} = $fh;
        $heap->{content_size} = 0;
    }
    else {
        return unless $heap->{request};

        $heap->{content_size} += length( $_[ARG0] );
        $heap->{content_fh}->print( $_[ARG0] );
        if( $heap->{content_size} >= $heap->{request}->headers( 'content-length' ) ) {
            delete $heap->{content_fh};
            delete $heap->{content_size};

            # Now we can parse $heap->{content_file}
            if( $heap->{request}->method eq 'POST' ) {
                handle_post( $heap );
            }
            else {
                # error ...
            }
        }
    }

    sub handle_post
    {
        my( $heap ) = @_;
        # Now we have to load and parse $heap->{content_file}            

        # Next 6 lines make the data available to CGI->init
        local $ENV{REQUEST_METHOD} = 'POST';
        local $CGI::PERLEX = $CGI::PERLEX = "CGI-PerlEx/Fake";
        local $ENV{CONTENT_TYPE} = $heap->{req}->header( 'content-type' );
        local $ENV{CONTENT_LENGTH} = $heap->{req}->header( 'content-length' );
        my $keep = IO::File->new( "<&STDIN" ) or die "Unable to reopen STDIN: $!";
        open STDIN, "<$heap->{content_file}" or die "Reopening STDIN failed: $!";

        my $qcgi = CGI->new();

        # cleanup
        open STDIN, "<&".$keep->fileno or die "Unable to reopen $keep: $!";
        undef $keep;
        unlink delete $heap->{content_file};

        # now use $q as you would normaly
        my $file = $q->upload( 'field_name' );
        
        # ....
    }

    sub handle_get
    {
        my( $heap ) = @_;

        # 4 lines to get data into CGI->init
        local $ENV{REQUEST_METHOD} = 'GET';
        local $CGI::PERLEX = $CGI::PERLEX = "CGI-PerlEx/Fake";   
        local $ENV{CONTENT_TYPE} = $heap->{req}->header( 'content-type' );
        local $ENV{'QUERY_STRING'} = $heap->{req}->uri->query;

        my $q = CGI->new();

        # now use $q as you would normaly
        # ....
    }

=head1 Streaming Response

It is possible to use POE::Filter::HTTPD for streaming content, but an
application can use it to send headers and then switch to
POE::Filter::Stream.

From the input handler (the InputEvent handler if you're using wheels,
or the ClientInput handler for POE::Component::Server::TCP):

  my $response = HTTP::Response->new(200);
  $response->push_header('Content-type', 'audio/x-mpeg');
  $_[HEAP]{client}->put($response);
  $_[HEAP]{client}->set_output_filter(POE::Filter::Stream->new());

Then the output-flushed handler (FlushEvent for POE::Wheel::ReadWrite,
or ClientFlushed for POE::Component::Server::TCP) can put() chunks of
the stream as needed.

  my $bytes_read = sysread(
    $_[HEAP]{file_to_stream}, my $buffer = '', 4096
  );

  if ($bytes_read) {
    $_[HEAP]{client}->put($buffer);
  }
  else {
    delete $_[HEAP]{file_to_stream};
    $_[KERNEL]->yield("shutdown");
  }

=head1 SEE ALSO

Please see L<POE::Filter> for documentation regarding the base
interface.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

L<HTTP::Request> and L<HTTP::Response> explain all the wonderful
things you can do with these classes.

=head1 BUGS

Many aspects of HTTP 1.0 and higher are not supported, such as
keep-alive.  A simple I/O filter can't support keep-alive, for
example.  A number of more feature-rich POE HTTP servers are on the
CPAN.  See
L<http://search.cpan.org/search?query=POE+http+server&mode=dist>

=head1 AUTHORS & COPYRIGHTS

POE::Filter::HTTPD was contributed by Artur Bergman.  Documentation is
provided by Rocco Caputo.

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
