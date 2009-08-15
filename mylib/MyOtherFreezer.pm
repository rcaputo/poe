# A sample external freezer for POE::Filter::Reference testing.

package MyOtherFreezer;

use strict;

sub new {
  my $type = shift;
  return bless [ ], $type;
}

sub freeze {
  my $thing = shift;
  $thing = shift if ref($thing) eq 'MyOtherFreezer';

  if (ref($thing) eq 'SCALAR') {
    return reverse(join "\0", ref($thing), $$thing);
  }
  elsif (ref($thing) eq 'Package') {
    return reverse(join "\0", ref($thing), @$thing);
  }
  die "can't freeze things of type ", ref($thing);
}

sub thaw {
  my $thing = shift;
  $thing = shift if ref($thing) eq 'MyOtherFreezer';

  my ($type, @stuff) = split /\0/, reverse($thing);
  if ($type eq 'SCALAR') {
    my $scalar = $stuff[0];
    return \$scalar;
  }
  elsif ($type eq 'Package') {
    return bless \@stuff, $type;
  }
  die "can't thaw things of type $type";
}

1;
