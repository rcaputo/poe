#!/usr/bin/perl

=head1 NAME

testreport.pl - generate a test report in xml

=head1 VERSION

$Revision$

=head1 USAGE

    perl -Ilib/ -I./ testreport.pl

This will output a file called C<poe_report.xml>.

=cut

package My::Strap;
use Test::Harness;
use base qw(Test::Harness::Straps);
use vars qw($VERSION);

$VERSION = (qw($Revision$))[1];

local $| = 1;

my $s = My::Strap->new;

my %handlers = (
    bailout     => sub {
        my($self, $line, $type, $totals) = @_;

        die sprintf "FAILED--Further testing stopped%s\n",
          $self->{bailout_reason} ? ": $self->{bailout_reason}" : '';
    },
    test        => sub {
        my($self, $line, $type, $totals) = @_;
        my $curr = $totals->{seen};

        if( $totals->{details}[-1]{ok} ) {
            $self->_display("ok $curr/$totals->{max}");
        }
        else {
            $self->_display("NOK $curr");
        }

        if( $curr > $self->{'next'} ) {
            $self->_print("Test output counter mismatch [test $curr]\n");
        }
        elsif( $curr < $self->{'next'} ) {
            $self->_print("Confused test output: test $curr answered after ".
                          "test ", $self->{next} - 1, "\n");
#            $self->{'next'} = $curr;
        }
    },
);

$s->{callback} = sub {
    my($self, $line, $type, $totals) = @_;
    print $line if $Test::Harness::Verbose;

    $handlers{$type}->($self, $line, $type, $totals) if $handlers{$type};
};


sub _display {
    my($self, $out) = @_;
    print "$ml$out";
}

sub _print {
    my($self) = shift;
    print @_;
}

my %test_results;
my $width = Test::Harness::_leader_width(<t/*.t>);
foreach my $file (<t/*.t>) {
    ($leader, $ml) = Test::Harness::_mk_leader($file, $width);
    print $leader;
    my %result = $s->analyze_file($file);
    delete $result{details};
    $file =~ s#^t/##;
    $test_results{$file} = \%result;
    $s->_display($result{passing} ? 'ok' : 'FAILED');
    print "\n";
}

my $xml = "<poe_test_report>\n";
$xml .= "<tests>\n";
foreach my $test_file (sort keys %test_results) {
    $xml .= "\t<test filename=\"$test_file\">\n";
    if(defined $test_results{$test_file}{skip_all}) {
        $xml .= "\t\t<skip_all>$test_results{$test_file}{skip_all}</skip_all>\n";
    } else {
        $xml .= "\t\t<expected>$test_results{$test_file}{max}</expected>\n";
        $xml .= "\t\t<seen>$test_results{$test_file}{seen}</seen>\n";
        $xml .= "\t\t<ok>$test_results{$test_file}{ok}</ok>\n";
        $xml .= "\t\t<skip>$test_results{$test_file}{skip}</skip>\n";
        $xml .= "\t\t<todo>$test_results{$test_file}{todo}</todo>\n";
    }
    $xml .= "\t</test>\n";
}
$xml .= "</tests>\n";

$xml .= "<system>\n";
eval {
    use POSIX;
    $xml .= "\t<machine>\n";
    my @sysinfo = uname();
    $xml .= "\t\t<sysname>$sysinfo[0]</sysname>\n";
    $xml .= "\t\t<nodename>$sysinfo[1]</nodename>\n";
    $xml .= "\t\t<release>$sysinfo[2]</release>\n";
    $xml .= "\t\t<version>$sysinfo[3]</version>\n";
    $xml .= "\t\t<machine>$sysinfo[4]</machine>\n";
    $xml .= "\t</machine>\n";
};
$xml .= "\t<perl_modules>\n";

eval "require POE;";
if($@) {
    $xml .= "\t\t<poe />\n";
} else {
    $xml .= "\t\t<poe version=\"$POE::VERSION\" />\n";
}
    
eval "use Gtk;";
if($@) {
    $xml .= "\t\t<gtk />\n";
} else {
    $xml .= "\t\t<gtk version=\"$Gtk::VERSION\" />\n";
}

eval "use Tk;";
if($@) {
    $xml .= "\t\t<tk />\n";
} else {
    $xml .= "\t\t<tk version=\"$Tk::VERSION\" />\n";
}

eval "use Event;";
if($@) {
    $xml .= "\t\t<event />\n";
} else {
    $xml .= "\t\t<event version=\"$Event::VERSION\" />\n";
}

eval "use IO::Tty;";
if($@) {
    $xml .= "\t\t<iotty />\n";
} else {
    $xml .= "\t\t<iotty version=\"$IO::Tty::VERSION\" />\n";
};

$xml .= "\t</perl_modules>\n";
$xml .= "</system>\n";
$xml .= "</poe_test_report>";

open OUT, "+>poe_report.xml";
print OUT $xml;
close OUT;


