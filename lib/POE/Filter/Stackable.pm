# 2001/01/25 shizukesa@pobox.com

# This implements a filter stack, which turns ReadWrite into something
# very, very interesting.

# 2001-07-26 RCC: I have no idea how to make this support get_one, so
# I'm not going to right now.

package POE::Filter::Stackable;

use strict;
use POE::Filter;

use vars qw($VERSION @ISA);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};
@ISA = qw(POE::Filter);

use Carp qw(croak);

sub FILTERS () { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  # Sanity check the filters
  if ( exists $params{Filters} and defined $params{Filters}
       and ref( $params{Filters} ) and ref( $params{Filters} ) eq 'ARRAY'
       and scalar @{ $params{Filters} } > 0 ) {

    # Check the elements
    foreach my $elem ( @{ $param{Filters} } ) {
      if ( ! defined $elem or ! UNIVERSAL::isa( $elem, 'POE::Filter' ) ) {
        croak "Filter element is not a POE::Filter instance!";
      }
    }

    my $self = bless [
      $params{Filters}, # FILTERS
    ], $type;

    return $self;
  } else {
    croak "Filters is not an ARRAY reference!";
  }
}

sub clone {
  my $self = shift;
  my $clone = bless [
    [ ],    # FILTERS
  ], ref $self;
  foreach my $filter (@{$self->[FILTERS]}) {
    push (@{$clone->[FILTERS]}, $filter->clone());
  }
  $clone;
}

#------------------------------------------------------------------------------

sub get_one_start {
  my ($self, $data) = @_;
  $self->[FILTERS]->[0]->get_one_start($data);
}

# RCC 2005-06-28: get_one() needs to strobe through all the filters
# regardless whether there's data to input to each.  This is because a
# later filter in the chain may produce multiple things from one piece
# of input.  If we stop even though there's no subsequent input, we
# may lose something.
#
# Keep looping through the filters we manage until get_one() returns a
# record, or until none of the filters exchange data.

sub get_one {
  my ($self) = @_;

  my $return = [ ];

  while (!@$return) {
    my $exchanged = 0;

    foreach my $filter (@{$self->[FILTERS]}) {

      # If we have something to input to the next filter, do that.
      if (@$return) {
        $filter->get_one_start($return);
        $exchanged++;
      }

      # Get what we can from the current filter.
      $return = $filter->get_one();
    }

    last unless $exchanged;
  }

  return $return;
}

# get() is inherited from POE::Filter.

#------------------------------------------------------------------------------

sub put {
  my ($self, $data) = @_;
  foreach my $filter (reverse @{$self->[FILTERS]}) {
    $data = $filter->put($data);
    last unless @$data;
  }
  $data;
}

#------------------------------------------------------------------------------

sub get_pending {
  my ($self) = @_;
  my $data;
  for (@{$self->[FILTERS]}) {
    $_->put($data) if $data && @{$data};
    $data = $_->get_pending;
  }
  $data || [];
}

#------------------------------------------------------------------------------

sub filter_types {
   map { ((ref $_) =~ /::(\w+)$/)[0] } @{$_[0]->[FILTERS]};
}

#------------------------------------------------------------------------------

sub filters {
  @{$_[0]->[FILTERS]};
}

#------------------------------------------------------------------------------

sub shift {
  my ($self) = @_;
  my $filter = shift @{$self->[FILTERS]};
  my $pending = $filter->get_pending;
  $self->[FILTERS]->[0]->put( $pending ) if $pending;
  $filter;
}

#------------------------------------------------------------------------------

sub unshift {
  my ($self, @filters) = @_;

  # Sanity check
  foreach my $elem ( @filters ) {
    if ( ! defined $elem or ! UNIVERSAL::isa( $elem, 'POE::Filter' ) ) {
      croak "Filter element is not a POE::Filter instance!";
    }
  }

  unshift(@{$self->[FILTERS]}, @filters);
}

#------------------------------------------------------------------------------

sub push {
  my ($self, @filters) = @_;

  # Sanity check
  foreach my $elem ( @filters ) {
    if ( ! defined $elem or ! UNIVERSAL::isa( $elem, 'POE::Filter' ) ) {
      croak "Filter element is not a POE::Filter instance!";
    }
  }

  push(@{$self->[FILTERS]}, @filters);
}

#------------------------------------------------------------------------------

sub pop {
  my ($self) = @_;
  my $filter = pop @{$self->[FILTERS]};
  my $pending = $filter->get_pending;
  $self->[FILTERS]->[-1]->put( $pending ) if $pending;
  $filter;
}

###############################################################################

1;

__END__

=head1 NAME

POE::Filter::Stackable - POE Multiple Filter Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Stackable(Filters => [ $filter1, $filter2 ]);
  $filter = new POE::Filter::Stackable;
  $filter->push($filter1, $filter2);
  $filter2 = $filter->pop;
  $filter1 = $filter->shift;
  $filter->unshift($filter1, $filter2);
  $arrayref_for_driver = $filter->put($arrayref_of_data);
  $arrayref_for_driver = $filter->put($single_data_element);
  $arrayref_of_data = $filter->get($arrayref_of_raw_data);
  $arrayref_of_leftovers = $filter->get_pending;
  @filter_type_names = $filter->filter_types;
  @filter_objects = $filter->filters;

=head1 DESCRIPTION

The Stackable filter allows the use of multiple filters within a
single wheel.  Internally, filters are stored in an array, with array
index 0 being "near" to the wheel's handle and therefore being the
first filter passed through using "get" and the last filter passed
through in "put".  All POE::Filter public methods are implemented as
though data were being passed through a single filter; other program
components do not need to know there are multiple filters.

=head1 PUBLIC FILTER METHODS

=over 4

=item *

POE::Filter::Stackable::new( ... )

The new() method creates the Stackable filter.  It accepts an optional
parameter "Filters" that specifies an arrayref of initial filters.  If
no filters are given, Stackable will pass data through unchanged; this
is true if there are no filters present at any time.

=item *

POE::Filter::Stackable::pop()
POE::Filter::Stackable::shift()
POE::Filter::Stackable::push($filter1, $filter2, ...)
POE::Filter::Stackable::unshift($filter1, $filter2...)

These methods all function identically to the perl builtin functions
of the same name.  push() and unshift() will return the new number of
filters inside the Stackable filter.

=item *

POE::Filter::Stackable::filter_types

The filter_types() method returns a list of types for the filters
inside the Stackable filter, in order from near to far; for example,
qw(Block HTTPD).

=item *

POE::Filter::Stackable::filters

The filters() method returns a list of the objects inside the
Stackable filter, in order from near to far.

=item *

See POE::Filter.

=back

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Reference;
POE::Filter::Line; POE::Filter::Block; POE::Filter::Stream

=head1 BUGS

Undoubtedly.  None currently known.

=head1 AUTHORS & COPYRIGHTS

The Stackable filter was contributed by Dieter Pearcey.  Rocco Caputo
is sure to have had his hands in it.

Please see the POE manpage for more information about authors and
contributors.

=cut

