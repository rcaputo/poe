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

TODO - As far as I know, this is not used anywhere.

POE supports XS versions of nearly all its mixin classes.  If
available, they are prefixed with POE::XS rather than POE.  This
POE::Loader class looks for POE::XS versions of the modules it's told
to load and falls back to the plain-Perl versions if they are not
avaibale.

Usage is simple:  use POE::Loader @list_of_modules_to_load.

=head1 BUGS

This module is a classic case of YDNI.  It was written well in advance
of any POE::XS modules.  To be fair, however, it was necessary to
write the loader to enable the XS modules, most of which remain
unwritten.

Design flaw aside, there are no known bugs in this module.

=head1 AUTHOR & COPYRIGHT

POE::Loader is Copyright 2004-2006 by Rocco Caputo.  All rights
reserved.  POE::Loader is released under the same terms as POE itself.

=cut
