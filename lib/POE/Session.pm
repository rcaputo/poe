package POE::Session;

# POD documentation exists after __END__

my $VERSION = 1.0;
my $rcs = '$Id$';

use strict;
use Carp;

#------------------------------------------------------------------------------

sub new {
  my ($type, $kernel, %states) = @_;

  my $self = bless {
                    'kernel'    => $kernel,
                    'namespace' => { },
                   }, $type;

  while (my ($state, $handler) = each(%states)) {
    $self->register_state($state, $handler);
  }

  if (exists $self->{'states'}->{'_start'}) {
    $kernel->session_alloc($self);
  }
  else {
    carp "discarding session $self - no '_start' state";
  }

  undef;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  delete $self->{'kernel'};
  delete $self->{'namespace'};
  delete $self->{'states'};
}

#------------------------------------------------------------------------------

sub _invoke_state {
  my ($self, $kernel, $source_session, $state, $etc) = @_;

  if ($self->{'debug'}) {
    print "$self -> $state\n";
  }

  if (exists $self->{'states'}->{$state}) {
    &{$self->{'states'}->{$state}}($kernel, $self->{'namespace'},
                                   $source_session, @$etc
                                  );
  }
  elsif (exists $self->{'states'}->{'_default'}) {
    &{$self->{'states'}->{'_default'}}($kernel, $self->{'namespace'},
                                       $source_session, $state, @$etc
                                      );
  }
}

#------------------------------------------------------------------------------

sub register_state {
  my ($self, $state, $handler) = @_;

  if ($handler) {
    if (ref($handler) eq 'CODE') {
      carp "redefining state($state) for session($self)"
        if (exists $self->{'states'}->{$state});
      $self->{'states'}->{$state} = $handler;
    }
    elsif ($self->{'debug'}) {
      print "$self : state($state) is not a CODE ref - not registered\n";
    }
  }
  else {
    delete $self->{'states'}->{$state};
  }
}

#------------------------------------------------------------------------------

sub debug {
  my ($self, $debug) = @_;

  $self->{'debug'} = $debug;
}

###############################################################################
1;
__END__

=head1 NAME

POE::Session - a state machine, driven by C<POE::Kernel>

=head1 SYNOPSIS

  new POE::Session(
    $kernel,
    '_start' => sub {
      my ($k, $me, $from) = @_;
      # initialize the session
    },
    '_stop'  => sub {
      my ($k, $me, $from) = @_;
      # shut down the session
    },
    '_default' => sub {
      my ($k, $me, $from, $state, @etc) = @_;
      # catches states for which no handlers are registered
    },
  );
                  
=head1 DESCRIPTION

C<POE::Session> builds an initial state table and registers it as a full
session with C<POE::Kernel>.  The Kernel will invoke C<_start> after the
session is registered, and C<_stop> just before destroying it.  C<_default>
is called when a signal is dispatched to a nonexistent handler.

=head1 PUBLIC METHODS

=over 4

=item new POE::Session($kernel, 'state' => sub { ... }, ....);

Build an initial state table, and register it with a C<$kernel>.  The
return value can be used for C<debug()>, but it usually is given to the
kernel to manage.

=item $session->debug($level)

Sets the debug level.  There are two levels, currently: 0 = no debugging;
1 = show events being dispatched to this session, and maybe some minor
warnings.

=back

=head1 PROTECTED METHODS

Not for general use.

=over 4

=item $session->_invoke_state($kernel, $source_session, $state, \@etc)

Called by C<POE::Kernel> to invoke state C<$state> generated from
C<$source_session> with a list of optional parameters in C<\@etc>.

=item $session->register_state($state, $handler)

Called by C<POE::Kernel> to add, change or remove states from this session.

=back

=head1 PRIVATE METHODS

=over 4

=item DESTROY

Destroys the session.  Deletes internal storage.

=back

=head1 EXAMPLES

Please see the tests directory that comes with the POE bundle.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
