# 2001/01/25 shizukesa@pobox.com

package POE::Filter::Map;

use strict;
use Carp qw(croak);

sub CODEBOTH () { 0 }
sub CODEGET  () { 1 }
sub CODEPUT  () { 2 }
sub BUFFER   () { 3 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  # -><- It might be better here for Code to set Get and Put first,
  # and then have Get and/or Put override that.  During the filter's
  # normal running (in the hotter code path), you won't need to keep
  # checking CODEBOTH or (CODEGET OR CODEPUT).  Rather, you'll just
  # check CODEGET or CODEPUT (depending on the direction data is
  # headed).

  croak "$type requires a Code or both Get and Put parameters" unless
    (defined($params{Code}) ||
     (defined($params{Get}) && defined($params{Put})));

  my $self = bless
    [ $params{Code}, # CODEBOTH
      $params{Get},  # CODEGET
      $params{Put},  # CODEPUT
      [ ],           # BUFFER
    ], $type;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $data) = @_;
  [ map &{$self->[CODEGET] || $self->[CODEBOTH]}, @$data ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $data) = @_;
  [ map &{$self->[CODEPUT] || $self->[CODEBOTH]}, @$data ];
}

#------------------------------------------------------------------------------
# 2001-07-26 RCC: The get_one variant of get() allows Wheel::Xyz to
# retrieve one filtered record at a time.  This is necessary for
# filter changing and proper input flow control, even though it's kind
# of slow.

sub get_one_start {
  my ($self, $stream) = @_;
  push(@{$self->[BUFFER]}, @$stream) if defined $stream;
}

sub get_one {
  my $self = shift;

  return [ ] unless @{$self->[BUFFER]};
  my $next_record = shift @{$self->[BUFFER]};
  return [ map &{$self->[CODEGET] || $self->[CODEBOTH]}, $next_record ];
}

#------------------------------------------------------------------------------
# 2001-07-27 RCC: This filter now tracks state, so get_pending has
# become useful.

sub get_pending {
  my $self = shift;
  return undef unless @{$self->[BUFFER]};
  [ @{$self->[BUFFER]} ];
}

#------------------------------------------------------------------------------

sub modify {
  my ($self, %params) = @_;
  for (keys %params) {
    next unless ($_ eq 'Put') || ($_ eq 'Get') || ($_ eq 'Code');
    $self->[ {Put  => CODEPUT,
              Get  => CODEGET,
              Code => CODEBOTH
             }->{$_}
           ] = $params{$_};
  }
}

###############################################################################

1;

__END__

=head1 NAME

POE::Filter::Map - POE Data Mapping Filter

=head1 SYNOPSIS

  $filter = POE::Filter::Map->new(Code => sub {...});
  $filter = POE::Filter::Map->new(Put => sub {...}, Get => sub {...});
  $arrayref_of_transformed_data = $filter->get($arrayref_of_raw_data);
  $arrayref_of_streamable_data = $filter->put($arrayref_of_data);
  $arrayref_of_streamable_data = $filter->put($single_datum);
  $filter->modify(Code => sub {...});
  $filter->modify(Put => sub {...}, Get => sub {...});

=head1 DESCRIPTION

The Map filter takes the coderef or coderefs it is given using the
Code, Get, or Put parameters and applies them to all data passing
through get(), put(), or both, as appropriate.  It it very similar to
the C<map> builtin function.

=head1 PUBLIC FILTER METHODS

=over 4

=item *

POE::Filter::Map::modify

Takes a list of parameters like the new() method, which should
correspond to the new get(), put(), or general coderef that you wish
to use.

=item *

See POE::Filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::Grep; POE::Filter::Line;
POE::Filter::Stackable; POE::Filter::Reference; POE::Filter::Stream;
POE::Filter::RecordBlock; POE::Filter::HTTPD

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

The Map filter was contributed by Dieter Pearcey.  Rocco Caputo is
sure to have had his hands in it.

Please see the POE manpage for more information about authors and
contributors.

=cut
