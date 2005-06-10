# $Id$

# Filter::Reference partial copyright 1998 Artur Bergman
# <artur@vogon-solutions.com>.  Partial copyright 1999 Philip Gwyn.

package POE::Filter::Reference;
use POE::Preprocessor ( isa => "POE::Macro::UseBytes" );

use strict;

use vars qw($VERSION @ISA);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};
@ISA = qw(POE::Filter);

use Carp qw(carp croak);

#------------------------------------------------------------------------------
# Try to require one of the default freeze/thaw packages.
use vars qw( $DEF_FREEZER $DEF_FREEZE $DEF_THAW );
BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';

  my @packages = qw(Storable FreezeThaw YAML);
  foreach my $package (@packages) {
    eval { require "$package.pm"; import $package (); };
    if ($@) {
      warn $@;
      next;
    }

    # Found a good freezer!
    $DEF_FREEZER = $package;
    last;
  }
  die "Filter::Reference requires one of @packages" unless defined $DEF_FREEZER;
}

# Some processing here
($DEF_FREEZE, $DEF_THAW) = _get_methods($DEF_FREEZER);

#------------------------------------------------------------------------------
# Try to acquire Compress::Zlib at runtime.

my $zlib_status = undef;
sub _include_zlib {
  local $SIG{'__DIE__'} = 'DEFAULT';

  unless (defined $zlib_status) {
    eval "use Compress::Zlib qw(compress uncompress)";
    if ($@) {
      $zlib_status = $@;
      eval(
        "sub compress   { @_ }\n" .
        "sub uncompress { @_ }"
      );
    }
    else {
      $zlib_status = '';
    }
  }

  $zlib_status;
}

#------------------------------------------------------------------------------

sub _get_methods {
  my($freezer)=@_;
  my $freeze=$freezer->can('nfreeze') || $freezer->can('freeze');
  my $thaw=$freezer->can('thaw');
  return unless $freeze and $thaw;
  return ($freeze, $thaw);
}

#------------------------------------------------------------------------------

sub new {
  my($type, $freezer, $compression) = @_;

  my($freeze, $thaw);
  unless (defined $freezer) {
    # Okay, load the default one!
    $freezer = $DEF_FREEZER;
    $freeze  = $DEF_FREEZE;
    $thaw    = $DEF_THAW;
  }
  else {
    # What did we get?
    if (ref $freezer) {
      # It's an object, create an closure
      my($freezetmp, $thawtmp) = _get_methods($freezer);
      $freeze = sub { $freezetmp->($freezer, @_) };
      $thaw   = sub { $thawtmp->  ($freezer, @_) };
    }
    else {
      # A package name?
      my $package = $freezer;

      $package =~ s(::)(\/)g;
      delete $INC{$package . ".pm"};

      eval {
        local $^W=0;
        require "$package.pm";
        import $freezer ();
      };
      carp $@ if $@;

      ($freeze, $thaw) = _get_methods($freezer);
    }
  }

  # Now get the methods we want
  carp "$freezer doesn't have a freeze or nfreeze method" unless $freeze;
  carp "$freezer doesn't have a thaw method" unless $thaw;

  # Should ->new() return undef() it if fails to find the methods it
  # wants?
  return unless $freeze and $thaw;

  # Compression
  $compression ||= 0;
  if ($compression) {
    my $zlib_status = _include_zlib();
    if ($zlib_status ne '') {
      warn "Compress::Zlib load failed with error: $zlib_status\n";
      carp "Filter::Reference compression option ignored";
      $compression = 0;
    }
  }

  my $self = bless {
    buffer    => '',
    expecting => undef,
    thaw      => $thaw,
    freeze    => $freeze,
    compress  => $compression,
  }, $type;
  $self;
}

#------------------------------------------------------------------------------

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

#------------------------------------------------------------------------------
# 2001-07-27 RCC: The get_one() variant of get() allows Wheel::Xyz to
# retrieve one filtered block at a time.  This is necessary for filter
# changing and proper input flow control.

sub get_one_start {
  my ($self, $stream) = @_;
  $self->{buffer} .= join('', @$stream);
}

sub get_one {
  my $self = shift;

  {% use_bytes %}

  while (
    defined($self->{expecting}) or
    (
      ($self->{buffer} =~ s/^(\d+)\0//s) and
      ($self->{expecting} = $1)
    )
  ) {
    return [ ] if length($self->{buffer}) < $self->{expecting};

    my $chunk = substr($self->{buffer}, 0, $self->{expecting});
    substr($self->{buffer}, 0, $self->{expecting}) = '';
    undef $self->{expecting};

    $chunk = uncompress($chunk) if $self->{compress};
    return [ $self->{thaw}->( $chunk ) ];
  }

  return [ ];
}

#------------------------------------------------------------------------------
# freeze one or more references, and return a string representing them

sub put {
  my ($self, $references) = @_;

  {% use_bytes %}

  my @raw = map {
    my $frozen = $self->{freeze}->($_);
    $frozen = compress($frozen) if $self->{compress};
    length($frozen) . "\0" . $frozen;
  } @$references;
  \@raw;
}

#------------------------------------------------------------------------------
# Return everything we have outstanding.  Do not destroy our framing
# buffer, though.

sub get_pending {
  my $self = shift;
  return undef unless length $self->{buffer};
  return [ $self->{buffer} ];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Reference - freeze data for sending; thaw data when it arrives

=head1 SYNOPSIS

  $filter = POE::Filter::Reference->new();
  $arrayref_of_perl_references =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_serialized_perl_references =
     $filter->put($arrayref_of_perl_references);

=head1 DESCRIPTION

This filter packages referenced data for writing to a file or socket.
Upon receipt of packaged data, it reconstitutes the original structure
and returns a reference to it.  This provides a handy way to ship data
between processes and systems.

=head1 PUBLIC FILTER METHODS

=over 2

=item new SERIALIZER, COMPRESSION

=item new SERIALIZER

=item new

new() creates and initializes a reference filter.  It accepts two
optional parameters: A serializer and a flag that determines whether
Compress::Zlib will be used to compress serialized data.

Serializers are modeled after Storable.  Storable has a nfreeze()
function which translates referenced data into strings suitable for
shipping across sockets.  It also contains a freeze() method which is
less desirable since it doesn't take network byte ordering into
effect.  Finally there's thaw() which translates frozen strings back
into data.

SERIALIZER may be a package name or an object reference, or it may be
omitted altogether.

If SERIALIZER is a package name, it is assumed that the package will
have a thaw() function as well as either an nfreeze() or a freeze()
function.

  # Use Storable explicitly, specified by package name.
  my $filter = POE::Filter::Reference->new("Storable");

  # Use YAML, perhaps to pass data to programs not written with POE or
  # even in Perl at all.
  my $filter = POE::Filter::Reference->new("YAML");

If SERIALIZER is an object reference, it's assumed to have a thaw()
method as well as either an nfreeze() or freeze() method.

  # Use an object.
  my $filter = POE::Filter::Reference->new($object);

If SERIALIZER is omitted or undef, the Reference filter will try to
use Storable, FreezeThaw, and YAML.  Filter::Reference will die if it
cannot find one of these serializers.

  # Use the default filter (either Storable, FreezeThaw, or YAML).
  my $filter = POE::Filter::Reference->new();

Filter::Reference will try to compress frozen strings and uncompress
them before thawing if COMPRESSION is true.  It uses Compress::Zlib
for this, but it works fine even without Zlib as long as COMPRESSION
is false.

An object serializer must have a thaw() method.  It also must have
either a freeze() or nfreeze() method.  If it has both freeze() and
nfreeze(), then Filter::Reference will use nfreeze() for portability.
The thaw() method accepts $self and a scalar; it should return a
reference to the reconstituted data.  The freeze() and nfreeze()
methods receive $self and a reference; they should return a scalar
with the reference's serialized representation.

If the serializer parameter is undef, a default one will be used.
This lets programs specify compression without having to worry about
naming a serializer.

For example:

  # Use the default filter (either Storable, FreezeThaw, or YAML).
  my $filter = POE::Filter::Reference->new();

  # Use an object, with compression.
  my $filter = POE::Filter::Reference->new($object, 1);

  # Use the default serializer, with compression.
  my $filter = POE::Filter::Reference->new(undef, 1);

The new() method will try to require any packages it needs.

The default behavior is to try Storable first, FreezeThaw second, YAML
third, and finally fail.

=item get [ FROZEN_DATA ]

The get() method thaws a referenced list of FROZEN_DATA chunks back
into references.  References will be blessed, if necessary.  If the
references points to an object, be sure the receiving end has used the
appropriate modules before calling their methods.

  $thingrefs = $filter_reference->get(\@stream_chunks);
  foreach (@$thingrefs) {
    ...;
  }

=item put [ REFERENCES ]

The put() method freezes one or more REFERENCES and returns their
serialized, streamable representations as a list reference.

  $listref = $filter_reference->put([ \%thing_one, \@thing_two ]);
  foreach (@$listref) {
    ...;
  }

=back

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Whatever is used to freeze and thaw data should be aware of potential
differences in system byte orders.  Also be careful that the same
freeze/thaw code is used on both sides of a socket.  That includes
even the most minor version differences.

=head1 AUTHORS & COPYRIGHTS

The Reference filter was contributed by Arturn Bergman, with changes
by Philip Gwyn.

Please see L<POE> for more information about authors and contributors.

=cut
