#!/usr/bin/perl

=head1 NAME

reportupload.pl - upload an xml test report

=head1 VERSION

$Revision$

=head1 USAGE

    perl -Ilib/ -I./ reportupload.pl

This will attempt to transmit a file called C<poe_report.xml> to a
central server for recording and browsing by POE's users and
development team.

=head1 AUTHOR

This program was written by Matt Cashner.

=cut

use IO::Socket::INET;
use strict;
local $/;

unless(open(XML, 'poe_report.xml')) {
    print "Cannot find 'poe_report.xml'.\n";
    exit(1);
}
my $xml = <XML>;
close XML;

print "Connecting to test server.\n";
my $sock = IO::Socket::INET->new(PeerHost => 'eekeek.org',
                                 PeerPort => 'http(80)',
                                 Proto => 'tcp',
                                );
if($sock && $sock->connected) {
    print "Connection to test server successful.\n";
} else {
    print "Connection to test server failed.\n";
    exit(1);
}
my $body = qq|
--MAGICPANTS
Content-Disposition: form-data; name="action"

upload
--MAGICPANTS
Content-Disposition: form-data; name="reportfile"; filename="poe_report.xml"
Content-Type: text/plain

$xml
--MAGICPANTS--
|;

my $length = length($body);
my $packet =<<EOP;
POST http://eekeek.org/poe-tests/ HTTP/1.0
User-Agent: reportupload.pl
Content-Type: multipart/form-data; boundary=MAGICPANTS 
Content-Length: $length

$body
EOP

print "Sending report...\n";
$sock->send($packet);

my $output;
$output = <$sock>; # for debug purposes
if($output =~ /Test Submission/) {
    print(
      "Report upload succeeded. Thank you for your contribution.\n",
      "Please visit http://eekeek.org/poe-tests/ to see other results.\n"
    );
} else {
    print "Report upload failed.\n";
}

$sock->shutdown(2); # Check please.
exit(0);

