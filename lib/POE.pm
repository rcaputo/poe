# $Id$
# Copyrights and documentation are after __END__.

package POE;

use strict;
use Carp;

use vars qw($VERSION);
$VERSION = 0.1003;

sub import {
  my $self = shift;
  my @modules = grep(!/^(Kernel|Session)$/, @_);
  unshift @modules, qw(Kernel Session);

  my $package = (caller())[0];

  my @failed;
  foreach my $module (@modules) {
    my $code = "package $package; use POE::$module;";
    eval($code);
    if ($@) {
      warn $@;
      push(@failed, $module);
    }
  }

  @failed and croak "could not import qw(" . join(' ', @failed) . ")";
}

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

#------------------------------------------------------------------------------
1;

__END__

=head1 NAME

POE - A Perl Object Environment

=head1 SYNOPSIS

  # Basic usage:

  use POE;
  # create initial sessions here
  $poe_kernel->run();
  exit;

  # Typical usage:

  use POE qw( Wheel::SocketFactory Wheel::ReadWrite
              Driver::SysRW Filter::Line
            );
  # create initial sessions here
  $poe_kernel->run();
  exit;

=head1 DESCRIPTION

The POE distribution contains a handful of different modules, each
doing something different.

When a program uses the POE module, the mandatory POE::Kernel and
POE::Session classes are included.  Other modules may be included in
the parameter to ``use POE''.  POE.pm will prepend ``POE::'' to the
module names for you.

=head1 CONCEPTUAL OVERVIEW

POE's features are separated into three major sections.  Sections are
called "layers" in the documentation because each builds atop others.

  +-----------+ +--------------+
  | I/O Layer | | Object Layer |
  +-----------+ +--------------+
       /|\            /|\         Commands (to events layer)
        |              |
        |              |
       \|/            \|/         Events (from events layer)
  +----------------------------+
  |        Events Layer        |
  +----------------------------+

Events are also used to pass messages between Sessions.

This is a description of each layer, starting with the lowest and
working upwards:

=head2 Events Layer

POE's events layer consists of two classes.  These classes are always
included when a program uses POE.  They may also be used separately
wherever their exported constants are needed.

POE::Kernel contains the state transition event queue and functions to
manage resources (including events).  Later on, these functions will
be referred to as "resource commands".  The Kernel will generate
events to indicate when watched resources (via a resource command)
become active.

POE::Session instances are state machines.  They consist of bundles of
related states.  States may be code references, object methods or
package subroutines.  States are invoked whenever a queued transition
event is dispatched.  State transitions may be enqueued by states
themselves or by active resources.

=head2 I/O Layer

The I/O layer contains one or more libraries that abstract file I/O.
Currently there is only one abstraction library, fondly known as
"Wheels".  The "Wheels" abstraction consists of groups of classes.

One type of object does only low-level file I/O.  These are the Driver
objects.

A second type of object translates between raw octet streams and
protocol packets.  These are the Filter objects.

The final type of object provides a functional interface to file I/O,
as well as the select logic to glue Drivers and Filters together.
These are the Wheel objects.

Here is a rough picture of the Wheels I/O abstraction:

  +----------------------------------------------------------+
  | Session                                                  |
  |                                                          |
  | +------------+  +-------+     +--------+    +--------+   |
  | |States      |  |       |     |        |    |        |   |
  | |            |  |       |     |        |    |        |   |
  | |Command     |  |       |     | Filter |    |        |   |
  | |events    --|->|       |<--->|        |--->|        |   |
  | |            |  | Wheel |     |        |    | Driver |   |
  | |Functions --|->|       |     +--------+    |        |<--|--> File 
  | |            |  |       |                   |        |   |
  | |Response    |  |       |-> Select Events ->|        |   |
  | |events    <-|--|       |                   |        |   |
  | +------------+  +-------+                   +--------+   |
  |   |   /|\         |  /|\                                 |
  |   |    |          |   |                                  |
  +---|----|----------|---|----------------------------------+
      |    |          |   |
      |    |          |   |   Commands (Session -> Kernel)
      |    |          |   |   & Events (Kernel -> Session)
     \|/   |         \|/  |
  +----------------------------------------------------------+
  |                                                          |
  |                          Kernel                          |
  |                                                          |
  +----------------------------------------------------------+

=head2 Object Layer

The Object layer consists of one or more libraries that implement
code objects.  Currently there are two ways code objects can be
created.

First, code may exist as plain Perl subroutines, objects and
packages.  This is the oldest object layer, and it is often the best
for most programming tasks.

The second object layer is still in its infancy.  Right now it
consists of four classes:

Curator.  This is the object manager.  It embodies inheritance,
attribute fetching and storage, method invocation and security.

Repository.  This is the object database.  It provides a consistent
interface between the Curator and whatever database it hides.

Object.  This is a Perl representation of a Repository object.  It
hides the Curator and Repository behind an interface that resembles a
plain Perl object.

Runtime.  This is a namespace where Object methods are run.  It
contains the public functions from Curator, Repository and Object, and
it may one day run within a Safe compartment.

The obligatory ASCII art:

  +--------------------------------------------------+
  |                     Runtime                      |
  | +----------------+                               |
  | | Object Methods |-------> Public Functions      |
  | +----------------+                               |
  |   /|\                          |                 |
  +----|---------------------------|-----------------+
       |                           |
       | Events                    |  Commands
       |                          \|/
  +--------------------------------------------------+
  |                                                  |
  |  +------------+     Curator                      |
  |  |            |                                  |
  |  |  Sessions  |  +-------------------------------+
  |  |            |  |
  |  +------------+  |   +------------+   +--======--+
  |    /|\     |     |<->| Repository |<->| Database |
  +-----|------|-----+   +------------+   +--======--+
        |      |
        |      |   Events & Commands
        |     \|/
  +--------------------------------------------------+
  |                                                  |
  |                      Kernel                      |
  |                                                  |
  +--------------------------------------------------+

=head1 EXAMPLES

As of this writing there are 24 sample programs.  Each illustrates and
tests some aspect of POE use.  They are included in the POE
distribution archive, but they are not installed.  If POE was
installed via the CPAN shell, then you should be able to find them in
your .cpan/build/POE-(version) directory.

=head2 Events Layer Examples

These sample programs demonstrate and exercise POE's events layer and
resource management functions.

=over 4

=item *

create.perl

This program is essentially the same as sessions.perl, but it uses the
newer &POE::Session::create constructor rather than the original
&POE::Session::new constructor.

=item *

forkbomb.perl

This program is an extensive test of Session construction and
destruction in the kernel.  Despite the name, it does not use fork(2).
By default, this program will stop after about 200 sessions, so it
shouldn't run away with machines it's run on.

Stopping forkbomb.perl with SIGINT is a good way to test signal
propagation.

=item *

names.perl

This program demonstrates the use of session aliases as a method of
"daemonizing" sessions and communicating between them by name.  It
also shows how to do non-blocking inter-session communication with
callback states.

=item *

objmaps.perl

This is a version of objsessions.perl that maps states to differently
named object methods.

=item *

objsessions.perl

This program is essentially the same as sessions.perl, but it uses
object methods as states instead of inline code references.

=item *

packagesessions.perl

This program is essentially the same as sessions.perl, but it uses
package functions as states instead of inline code references.

=item *

poing.perl

This is a quick and dirty multiple-host icmp ping program.  Actually,
it's getting better as creatures feep; it may be useful enough to be a
separate program.  It requires a vt100 or ANSI terminal.  It needs to
be run by root, since it expects to open a raw socket for ICMP
pinging.

I thank Russell Mosemann <mose@ccsn.edu> for the Net::Ping module,
which I "borrowed" heavily from.  Net::Ping is the route of choice if
you don't need parallel ping capability.

=item *

selects.perl

This program exercises the POE::Kernel interface to select(2).  It
creates a simple chargen server, and a simple client to visit it.  The
client will disconnect after receiving a few lines from the server.
The server will remain active, and it will accept telnet connections.

=item *

sessions.perl

This program is a basic test of Session construction, destruction and
maintenance in the Kernel.  It is much more friendly than
forkbomb.perl.  People who are new to POE may want to look at this
test first.

=item *

signals.perl

This program is a basic test of the POE::Kernel interface to system
and Session signals.  It creates two sessions that wait for signals
and periodically send signals to themselves.

=back

=head2 I/O Layer Examples

These sample programs demonstrate and exercise POE's default I/O
layer.

=over 4

=item *

fakelogin.perl

This program tests the ability for POE::Wheel instances to change the
events they emit.  The port it listens on can be specified on the
command line.  Its default listen port is 23.

=item *

filterchange.perl

This program tests the ability for POE::Wheel instances to change the
filters they use to process information.

=item *

followtail.perl

This program tests POE::Wheel::FollowTail, a read-only wheel that
follows the end of an ever-growing file.

It creates 21 sessions: 10 log writers, 10 log followers, and one loop
to make sure none of the other 20 are blocking.  SIGINT should stop
the program and clean up its /tmp files.

=item *

httpd.perl

This program tests POE::Filter::HTTPD by implementing a very basic web
server.  It will try to bind to port 80 of every available interface,
and it will not run if something has already bound to port 80.  It
will accept a new port number on the command line:

  ./httpd.perl 8080

=item *

ref-type.perl

This program tests the ability for POE::Filter::Reference to use
specified serialization methods.  It is part of Philip Gwyn's work on
XML based RPC.

=item *

refsender.perl and refserver.perl

These two programs test POE::Filter::Reference's ability to pass
blessed and unblessed references between processes.  The standard
Storable caveats (such as the inability to freeze and thaw CODE
references) apply.

To run this test, first start refserver, then run refsender.  Check
refserver's STDOUT to see if it received some data.

=item *

socketfactory.perl

This program tests POE::Wheel::SocetFactory, a high level wheel that
creates listening and connecting sockets.  It creates a server and
client for each socket type it currently supports.  The clients visit
the servers and process some sample transactions.

=item *

thrash.perl

This program tests the Wheel abstraction's ability to handle heavy
loads.  It creates a simple TCP daytime server and a pool of 5 clients
within the same process.  Each client connects to the server, accepts
the current time, and destructs.  The client pool creates replacements
for destroyed clients, and so it goes.

This program has been known to exhaust some systems' available
sockets.  On systems that are susceptible to socket exhaustion,
netstat will report a lot of sockets in various WAIT states, and
thrash.perl will show an abnormally low connections/second rate.

=item *

udp.perl

Udp shows how to use UDP sockets with Kernel::select calls.

=item *

watermarks.perl

This program is a cross between wheels.perl (wheel-based server) and
selects.perl (chargen service).  It creates a chargen service (on port
32019) that uses watermark events to pause output when the unflushed
write buffer reaches about 512 bytes.  It resumes spewing chargen
output when the client finally reads what's waiting for it.

There currently is no program to act as a slow client for it.  Telnet
or other raw TCP clients may work, especially if the client is running
at maximum niceness.

=item *

wheels.perl

This program is a basic rot13 server.  It is a basic test of the whole
premise of wheels.

=item *

wheels2.perl

Wheels2 shows how to use separate input and output filehandles with
wheels.  It's a simple raw tcp socket client, piping between a client
socket and stdio (in cooked mode).

=back

=head2 Object Layer Examples

This program illustrates POE's Object Layer, which is still in early
development.

=over 4

=item *

olayer.perl

This program demonstrates some of the features of the early Object
Layer implementation.  It's also something of a reference standard, to
make sure that the Object Layer is consistent and usable.

=back

=head2 Proofs of Concepts

Proofs of concepts mainly show how to do something with POE.  In some
cases, they prove that the concept is possible, even though it wasn't
considered while POE was being designed.

=over 4

=item *

poing.perl

Poing is a ping program that can check multiple hosts at the same
time.  Historical information scrolls across the screen in a "strip
chart" fashion.  It's great for listening to the seismology of your
local network (no, it's not deliberately a Quake reference).

Poing's event-driven pinger "borrows" heavily from Net::Ping.

=item *

preforkedserver.perl

This program demonstrates a way to write pre-forking servers with POE.
It tends to dump core after a while.  Perl still isn't safe with
signals, especially in a long-running daemon process.

One work-around is to comment out the yield('_stop') calls (there are
two).  They only exist to cycle the child servers.  That idea was
borrowed from Apache, which only did it to thwart memory leaks.  POE
shouldn't leak memory, so churning the children shouldn't be needed.

=item *

proxy.perl

This program demonstrates a way to write TCP forwarders with POE.

=item *

tutorial-chat.perl

This program is a heavily commented "chat" program.  It contains a
running narrative of what's going on and is intended to be both
functional and educational.

=back

=head1 SEE ALSO

=over 4

=item *

Events Layer

POE::Kernel; POE::Session

=item *

I/O Layer

POE::Driver; POE::Driver::SysRW POE::Filter; POE::Filter::HTTPD;
POE::Filter::Line; POE::Filter::Reference; POE::Filter::Stream;
POE::Wheel; POE::Wheel::FollowTail; POE::Wheel::ListenAccept;
POE::Wheel::ReadWrite; POE::Wheel::SocketFactory

=item *

Object Layer

POE::Curator; POE::Object; POE::Repository; POE::Repository::Array;
POE::Runtime

=back

=head1 BUGS

The Object Layer is still in early design and implementation, so it's
not documented yet.

There are no automated regression tests.

=head1 AUTHORS & COPYRIGHTS

POE is brought to you by the following people:

=head2 Contributors

All contributions are Copyright 1998-1999 by their respective
contributors.  All rights reserved.  Contributions to POE are free
software, and they may be redistributed and/or modified under the same
terms as Perl itself.

=over 4

=item *

Artur Bergman

Artur Bergman is <vogon-solutions.com!artur>.

He has contributed Filter::HTTPD and Filter::Reference.  His
intangible contributions include feedback, testing, conceptual
planning and inspiration.  POE would not be as far along without his
support.

=item *

Philip Gwyn

Philip Gwyn is <artware.qc.ca!gwynp>.

He has extended the Wheels I/O abstraction to allow filters to be
changed at runtime.  He has enhanced Filter::Reference to support
different serialization methods.  His intangible contributions include
feedback and quality assurance (bug finding).  A lot of cleanup
between 0.06 and 0.07 is a result of his keen eye.  His other eye's
not so bad either.

=item *

Dave Paris

Dave Paris is <w3works.com!dparis>.

His contributions include testing and benchmarking.  He discovered
some subtle (and not so subtle) timing problems in version 0.05.  The
pre-forking server test was his idea.  Versions 0.06 and later should
scale to higher loads because of his work.

=item *

Robert Seifer

Robert Seifer is <?!?>.

He contributed entirely too much time, both his own and his
computer's, to the detection and eradication of a memory corruption
bug that POE tickled in Perl.  In the end, his work produced a patch
that circumvents problems found relating to anonymous subs, scope and
@{} processing.

=item *

Others?

Have I forgotten someone?  Please let me know.

=back

=head2 Author

=over 4

=item *

Rocco Caputo

Rocco Caputo is <netrus.net!troc>.  POE is his brainchild.

Except where otherwise noted, POE is Copyright 1998-1999 Rocco Caputo.
All rights reserved.  POE is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut
