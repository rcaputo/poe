# $Id$

package POE::Resource;

use vars qw($VERSION);
$VERSION = (qw($Revision$))[1];

use Carp qw(croak);

sub new {
  my $type = shift;
  croak "$type is a virtual base class and not meant to be used directly";
}

1;

__END__

=head1 NAME

POE::Resource - documentation for POE's internal event watchers/generators

=head1 SYNOPSIS

  Varies.

=head1 DESCRIPTION

POE manages several types of information internally.  Its Resource
classes are designed to manage those types of information behind tidy,
encapsulated interfaces.  This allows us to test them individually, as
well as re-implement them in C without porting POE::Kernel all at
once.

Currently every POE::Resource class is sufficiently different from the
rest that there isn't much to document here.  There are however
similarities between them that should be noted.

While it's not currently the case, every resource should have
initializer and finalizer functions.

Initializers act to link resources to POE::Kernel, usually by swapping
lexically scoped variable references between Kernel.pm and each
resource's source scopes.

Finalizers clean up any remaining data and also verify that each
resource's subsystem was left in a consistent state.

At some future time, resources will be loaded dynamically and will
need to register their initializers and finalizers with POE::Kernel.
Otherwise POE::Kernel won't know which to call.

One common theme in resource implementations is that they don't need
to perform much error checking, if any.  Resource methods are used
internally by POE::Kernel and/or APIs (programmer interfaces), so it's
up to them to ensure that they're used correctly.

Resource methods follow the naming convention _data_???_activity,
where ??? is an abbreviation for the type of resource it belongs to:

  POE::Resource::Events      _data_ev_initialize
  POE::Resource::FileHandles _data_handle_initialize
  POE::Resource::Signals     _data_sig_initialize

Finalizer methods end in "_finalize".

We may be able to take advantage of this later by skimming
POE::Kernel's namespace for initializers and finalizers automatically.

=head1 SEE ALSO

L<POE::Resource::Aliases>, 
L<POE::Resource::Events>, 
L<POE::Resource::Extrefs>, 
L<POE::Resource::FileHandles>, 
L<POE::Resource::SIDs>, 
L<POE::Resource::Sessions>, 
L<POE::Resource::Signals>

=head1 BUGS

This documentation, and resource specification, are incomplete.  We
are developing it as a rationale after the fact for practices that
have developed over several months.

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about its authors,
contributors, and POE's licensing.

=cut
