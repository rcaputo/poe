# $Id$
# Documentation exists after __END__

# Filter::HTTPD copyright 1998 Artur Bergman <artur@vogon.se>.

# Thanks go to Gisle Aas for his excellent HTTP::Daemon.  Some of the
# get code was copied out if, unfournatly HTTP::Daemon is not easily
# subclassed for POE because of the blocking nature.

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::HTTPD;
use HTTP::Status;
use HTTP::Request;
use HTTP::Date qw(time2str);
use URI::URL qw(url);
use strict;

my $HTTP_1_0 = _http_version("HTTP/1.0");
my $HTTP_1_1 = _http_version("HTTP/1.1");

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = { type => 0,
	       buffer => '',
               finish => 0,
	     };
  bless $self, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;


  local($_);
  
  if($self->{'finish'}) {
    die "Didn't want any more data\n";
  }

  $self->{buffer} .= join('', @$stream);

  if($self->{header}) {
    my $buf = $self->{buffer};
    my $r = $self->{header};
    $buf =~s/.*(\x0D\x0A?\x0D\x0A?|\x0A\x0D?\x0A\x0D?)//s;
    if(length($buf) >= $r->content_length()) {
      $r->content($buf);
      $self->{finish}++;
      return [$r];      
    } else {
      print $r->content_length()." wanted, got ".length($buf)."\n";
    }
    return [];
  }
     


  


  return [] unless($self->{buffer} =~/(\x0D\x0A?\x0D\x0A?|\x0A\x0D?\x0A\x0D?)/s);

  my $buf = $self->{buffer};



  if ($buf !~ s/^(\w+)[ \t]+(\S+)(?:[ \t]+(HTTP\/\d+\.\d+))?[^\012]*\012//) {
    $self->send_error(400);  # BAD_REQUEST
    return [];
  }
  my $proto = $3 || "HTTP/0.9";

  my $r = HTTP::Request->new($1, url($2));
  $r->protocol($proto);
  $self->{'httpd_client_proto'} = $proto = _http_version($proto);

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

  if($r->method() eq 'GET') {
    $self->{finish}++;
    return [$r];
  }



  if($r->method() eq 'POST') {

#    print "post:$buf:\END BUFFER\n";
#    print length($buf)."-".$r->content_length()."\n";
    if(length($buf) >= $r->content_length()) {
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
  my @raw = map { 'HTTP ' . $_->as_string(); } @$responses;
  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending 
{
    my($self)=@_;
    warn ref($self)." does not support the get_pending() method\n";
    return;
}


#------------------------------------------------------------------------------
#function specific to HTTPD;
#------------------------------------------------------------------------------

sub send_basic_header {
  my $self = shift;
  $self->send_status_line(@_);
  $self->put("Date: ", time2str(time));
}

sub _http_version {
  local($_) = shift;
  return 0 unless m,^(?:HTTP/)?(\d+)\.(\d+)$,i;
  $1 * 1000 + $2;
}

sub send_status_line {
    my($self, $status, $message, $proto) = @_;
    $status  ||= RC_OK;
    $message ||= status_message($status) || "";
    $proto   ||= "HTTP/1.1";
    $self->put("$proto $status $message");
}


sub send_error {
    my($self, $status, $error) = @_;
    $status ||= RC_BAD_REQUEST;
    my $mess = status_message($status);
    $error  ||= "";
    $mess = <<EOT;
<title>$status $mess</title>
<h1>$status $mess</h1>
$error
EOT

    $self->send_basic_header($status);
    $self->put("Content-Type: text/html");
    $self->put("Content-Length: " . length($mess));
    $self->put("");
    $self->put("$mess");
    $status;
}


###############################################################################
1;
__END__

=head1 NAME

POE::Filter::HTTPD - Supports the HTTP 1.0 Protocol

=head1 SYNOPSIS

  $httpd = new POE::Filter::HTTPD();

  $http_response_as_string = $httpd->put($full_http_response_object);

  $http_request_object = $line->get($http_request_string);


=head1 DESCRIPTION

Breaks up a httpstream into a HTTP::Request object, accepts a HTTP::Response object that it sends back to the client.

=head1 PUBLIC METHODS

Please see C<POE::Filter> for explanations.

=head1 EXAMPLES

Please see tests/httptest.perl for examples of C<POE::Filter::HTTPD>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


