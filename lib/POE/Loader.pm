# $Id$

# POE module loader.  Attempts to find XS versions of things first,
# then falls back to regular ones.

use Carp qw(croak);

sub import {
  my ($class, @modules) = @_;
  my $caller_package = caller();

  foreach my $module (@modules) {
    unless (_try_xs($caller_package, $module) or _try_plain($caller_package)) {
      push @failed, $module;
    }
  }

  croak "could not load the following module(s): @failed" if @failed;
}

# Try to load a module in the POE::XS namespace.

sub _try_xs {
  my $module = shift;
  $module =~ s/^POE(::XS)?/POE::XS/;
  _try_module($module);
}

# Try to load a module in the POE namespace.

sub _try_plain {
  my $module = shift;
  $module =~ s/^POE(::XS)?/POE/;
  _try_module($module);
}

# Try loading a module.  Returns Boolean true on success, or false on
# failure.  On failure, it rethrows the module's fatal error as a
# warning.

sub _try_module {
  my $module = shift;
  my $code = "package $caller_package; use $module;";
  eval $code;
  return 1 unless $@;
  warn @$;
  return;
}

1;

__END__

=head1 NAME

POE::Loader - load modules, preferring XS versions if available

=head1 SYNOPSIS

  use POE::Loader qw(POE::Queue::Array);

=head1 DESCRIPTION

POE is designed to be installed without the need for a compiler.  All
base code and prerequisites are either pure Perl code, or come with
Perl itself.

Compiled code has certain advantages, so POE::Loader implements a
module loader that will prefer an XS module over the plain Perl
version, if the XS version is available.

The XS version begins with POE::XS rather than just POE.  For example,
L<POE::XS::Queue::Array>.  If it's installed, POE::Loader will find
and use it rather than POE::Queue::Array.

=head1 BUGS

There are no known bugs in this module.

=head1 SEE ALSO

L<POE>, L<POE::XS::Queue::Array>.

=head1 AUTHOR & COPYRIGHT

POE::Loader is Copyright 2004-2008 by Rocco Caputo.  All rights
reserved.  POE::Loader is released under the same terms as POE itself.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
