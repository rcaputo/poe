# $Id$
# Copyrights and documentation are after __END__.

package POE;

use strict;
use Carp;

use vars qw($VERSION);
$VERSION = '0.110002';

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

POE - a persistent object environment

=head1 SYNOPSIS

  #!/usr/bin/perl -w
  use strict;

  # Use POE!
  use POE;

  # Every machine is required to have a special state, _start, which
  # is used to the machine it has been successfully instantiated.
  # $_[KERNEL] is a reference to the process' global POE::Kernel
  # instance; $_[HEAP] is the session instance's local storage;
  # $_[SESSION] is a reference to the session instance itself.

  sub state_start {
    my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
    print "Session ", $session->ID, " has started.\n";
    $heap->{count} = 0;
    $kernel->yield('increment');
  }

  sub state_increment {
    my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
    print "Session ", $session->ID, " counted to ", ++$heap->{count}, ".\n";
    $kernel->yield('increment') if $heap->{count} < 10;
  }

  # The _stop state is special but not required.  POE uses it to tell
  # a session instance that it is about to be destroyed.  Stop states
  # contain last-minute resource cleanup, which often isn't necessary
  # since POE destroys $_[HEAP], and resource destruction cascades
  # down from there.

  sub state_stop {
    print "Session ", $_[SESSION]->ID, " has stopped.\n";
  }

  # Start ten instances of a session.  POE::Session constructors map
  # state names to the code that handles them.

  for (0..9) {
    POE::Session->create(
      inline_states =>
        { _start    => \&state_start,
          increment => \&state_increment,
          _stop     => \&state_stop,
        }
    );
  }

  # Start the kernel, which will run as long as there are sessions.

  $poe_kernel->run();
  exit;

=head1 DESCRIPTION

POE is an acronym of "Persistent Object Environment".  It originally
was designed as the core of a persistent object server where clients
and autonomous objects could interact in a sort of "agent space".  It
was, in this regard, very much like a MUD.  Evolution, however, seems
to have other plans.

POE's heart is a framework for event driven state machines.  This
heart has two chambers: an event dispatcher and state machines that
are driven by dispatched events.  The modules are, respectively,
POE::Kernel and POE::Session.

The remainder of POE consists of modules that help perform high-level
functions.  For example, POE::Wheel::ReadWrite encapsulates the logic
for select-based I/O.  Module dependencies always point towards lower
level code.  POE::Kernel and POE::Session, being at the lowest level,
need none of the others.  Since they are always required, they will be
used whenever POE itself is.

=head1 USING POE

Using POE modules can be pretty tedious.  Consider this example, which
pulls in the necessary modules for a line-based TCP server:

  use POE::Kernel;
  use POE::Session;
  use POE::Wheel::SocketFactory;
  use POE::Wheel::ReadWrite;
  use POE::Filter::Line;
  use POE::Driver::SysRW;

Using POE directly optimizes this for laziness in two ways.  First, it
brings in POE::Kernel and POE::Session for you.  Second, subsequent
modules can be passed as parameters to the POE module without the
"POE::" prefix.

The preceding example can then be written as:

  use POE qw( Wheel::SocketFactory Wheel::ReadWrite
              Filter::Line Driver::SysRW
            );

=head1 WRITING POE PROGRAMS

Basic POE programs consist of four parts.

=over 2

=item *

Preliminary program setup

This is the usual overhead for writing a Perl program: a C<#!> line,
perhaps some C<use> statements to import things, and maybe some global
variables or configuration constants.  It's all pretty standard stuff.

  #!/usr/bin/perl -w
  use strict;
  use POE;

=item *

Define the program's states

Here's where the code for each state is defined.  In a procedural
program, it would be where subroutines are defined.  This part is
optional in smaller programs, since states may be defined as inline
anonymous coderefs when machines are instantiated.

  sub state_start {
    ...
  }

  sub state_increment {
    ...
  }

  sub state_stop {
    ...
  }

=item *

Instantiate initial machines

POE's kernel stops when there are no more sessions to generate or
receive transition events.  A corolary to this rule: The kernel won't
even begin unless a session first has been created.  The SYNOPSIS
example starts ten state machines to illustrate how POE may simulate
threads through cooperative timeslicing.  In other words, several
things may be run "concurrently" by taking a little care in their
design.

  for (0..9) {
    POE::Session->create(
      inline_states =>
        { _start    => \&state_start,
          increment => \&state_increment,
          _stop     => \&state_stop,
        }
    );
  }

=item *

Start the kernel

Almost nothing will happen until the event dispatcher starts.  A
corolary to this rule: Nothing of much consequence will happen until
the kernel is started.  As was previously mentioned, the kernel won't
return until everything is finished.  This usually (but not
necessarily) means the entire program is done, so it's common to exit
or otherwise let the program end afterwards.

  $poe_kernel->run();
  exit;

=back


=head1 POE's ARCHITECTURE

POE is built in distinct strata: Each layer requires the ones beneath
it but not the ones above it, allowing programs to use as much code as
they need but no more.  The layers are:

=over 2

=item *

Events layer

This was already discussed earlier.  It consists of an event
dispatcher, POE::Kernel, and POE::Session, which is a generic state
machine.

=item *

The "Wheels" I/O abstraction

POE::Wheel is conceptually similar to a virus.  When one is
instantiated, it injects its code into the host session.  The code
consists of some unspecified states that perform a particular job.
Unlike viruses, wheels remove their code when destroyed.

POE comes with four wheels so far:

=over 2

=item *

POE::Wheel::FollowTail

FollowTail follows the tail of an ever-growing file.  It's useful for
watching logs or pipes.

=item *

POE::Wheel::ListenAccept

ListenAccept performs ye olde non-blocking socket listen and accept.
It's depreciated by SocketFactory, which does all that and more.

=item *

POE::Wheel::ReadWrite

ReadWrite is the star of the POE::Wheel family.  It performs buffered
I/O on unbuffered, non-blocking filehandles.  It almost acts like a
Unix stream, only the line disciplines don't yet support push and pop.

ReadWrite uses two other classes to do its dirty work: Driver and
Filter.  Drivers do all the work, reading and/or writing from
filehandles.  Filters do all the other work, translating serialized
raw streams to and from logical data chunks.

Drivers first:

=over 2

=item *

POE::Driver::SysRW

This is the only driver currently available.  It performs sysread and
syswrite on behalf of Wheel::ReadWrite.  Other drivers, such as
SendRecv, are possible, but so far there hasn't been a need for them.

=back

Filters next:

=over 2

=item *

POE::Filter::Block

This filter parses input as fixed-length blocks.  The output side
merely passes data through unscathed.

=item *

POE::Filter::HTTPD

This filter parses input as HTTP requests, translating them into
HTTP::Request objects.  It accepts responses from the program as
HTTP::Response objects, serializing them back into streamable HTTP
responses.

=item *

POE::Filter::Line

The Line filter parses incoming streams into lines and serializes
outgoing lines into streams.  It's very basic.

=item *

POE::Filter::Reference

The Reference filter is used for sending Perl structures between POE
programs.  The sender provides references to structures, and
Filter::Reference serializes them with Storable, FreezeThaw, or a
serializer of your choice.  Data may optionally be compressed if Zlib
is installed.

The receiving side of this filter takes serialized data and thaws it
back into perl data structures.  It returns a reference to the
reconstituted data.

=item *

POE::Filter::Stream

Filter::Stream does nothing of consequence.  It passes data through
without any change.

=back

=item *

POE::Wheel::SocketFactory

SocketFactory creates sockets.  When creating connectionless sockets,
such as UDP, it returns a fully formed socket right away.  For
connecting sockets which may take some time to establish, it returns
when a connection finally is made.  Listening socket factories may
return several sockets, one for each successfully accepted incoming
connection.

=back

=back

=head1 POE COMPONENTS

A POE component consists of one or more state machines that
encapsulates a very high level procedure.  For example,
POE::Component::IRC (not included) performs nearly all the functions
of a fully featured IRC client.  This frees programmers from the
tedium of working directly with the protocol, instead letting them
focus on what the client will actually do.

POE comes with only one core component, POE::Component::Server::TCP.
It is a thin wrapper around POE::Wheel::SocketFactory, providing the
wheel with some common default states.  This reduces the overhoad
needed to create TCP servers to its barest minimum.

To-do: Publish a POE component SDK, which should amonut to little more
than some recommended design guidelines and MakeMaker templates for
CPAN publication.

=head1 Support Modules

Finally, there are some modules which aren't directly used but come
with POE.  These include POE::Preprocessor and the virtual base
classes: POE::Component, POE::Driver, POE::Filter and POE::Wheel.

POE::Preprocessor is a macro processor.  POE::Kernel and POE::Session
use it to inline common code, making the modules faster and easier to
maintain.  There seem to be two drawbacks, however: Code is more
difficult to examine from the Perl debugger, and programs take a
little longer to start.  The compile-time penalty is negligible in the
types of long-running programs POE excels at, however.

POE::Component exists merely to explain the POE::Component subclasses,
as do POE::Driver, POE::Filter and POE::Wheel.  Their manpages also
discuss options and methods which are common across all their
subclasses.

=head1 ASCII ART

The ASCII art is gone.  If you want pretty pictures, contact the
author.  He's been looking for excuses to sit down with a graphics
program.

=head1 OBJECT LAYER

The object layer has fallen into disrepair again, and the author is
considering splitting it out as a separate Component.  If you've been
looking forward to it, let him know so he'll have an excuse to
continue with it.

=head1 SAMPLE PROGRAMS

The POE contains 28 sample programs as of this writing.  Please be
advised that some of them date from the early days of POE's
development and may not exhibit the best coding practices.

The samples reside in the archive's ./samples directory.  The author
is considering moving them to a separate distribution to cut back on
the archive's size, but please contact him anyway if you'd like to see
something that isn't there.

=head2 Tutorials

POE's documentation is merely a reference.  It may not explain why
things happen or how to do things with POE.  The tutorial samples are
meant to compensate for this in some small ways.

=over 2

=item *

tutorial-chat.perl

This is the first and only tutorial to date.  It implements a simple
chat server (not web chat) with rambling narrative comments.

=back

=head2 Events Layer Examples

These examples started life as test programs, but the t/*.t type tests
are thousands of times terrificer.  Now the examples exist mainly as
just examples.

=over 2

=item *

create.perl

This program is essentially the same as sessions.perl, but it uses the
newer POE::Session->create constructor rather than the original
POE::Session->new one.

=item *

forkbomb.perl

The "forkbomb" test doesn't really use fork, but it applies the
fork-til-you-puke concept to POE's sessions.  Every session starts two
more and exits.  It has a 200 session limit to keep it from eating
resources forever.

=item *

names.perl

The "names" test demonstrates two concepts: how to reference sessions
by name, and how to communicate between sessions with an asynchronous
ENQ/ACK protocol.

=item *

objmaps.perl

This is a version of objsessions.perl that maps states to differently
named object methods.

=item *

objsessions.perl

This program is essentially the same as sessions.perl, but it uses
object methods as states instead of inline coderefs.

=item *

packagesessions.perl

This program is essentially the same as sessions.perl, but it uses
package methods as states instead of inline coderefs.

=item *

queue.perl

In this example, a single session is created to manage others beneath
it.  The main session keeps a pool of children to perform asynchronous
tasks.  Children stop as their tasks are completed, so the job queue
controller spawns new ones to continue the work.  The pool size is
limited to constrain the example's resource use.

=item *

selects.perl

The "selects" example shows how to use POE's interface to select(2).
It creates a simple chargen server and a client to visit it.  The
client will disconnect after receiving a few lines from the server.
The server will remain active until it receives SIGINT, and it will
accept further socket connections.

=item *

sessions.perl

This program is a basic example of Session construction, destruction
and maintenance.  It's much more system friendly than forkbomb.perl.

=item *

signals.perl

The "signals" example shows how sessions can watch for signals.  It
creates two sessions that wait for signals and periodically post soft
signals to themselves.  Soft signals avoid the underlying operating
system, posting signal events directly through POE.  This also allows
simulated and fictitious signals.

=back

=head2 I/O Layer Examples

These examples show how to use the Wheels abstraction.

=over 2

=item *

fakelogin.perl

The "fakelogin" example tests Wheels' ability to change the events
they emit.  The port it listens on can be specified on the command
line, and it listens on port 23 by default.

=item *

filterchange.perl

This example tests POE::Wheel::ReadWrite's ability to change the
filter it's using while it runs.

=item *

followtail.perl

This program shows how to use POE::Wheel::FollowTail, a read-only
wheel that follows the end of an ever-growing file.

It creates 21 sessions: 10 that generate fictitious log files, 10 that
follow the ends of these logs, and one timer loop to make sure none of
the other 20 are blocking.  SIGINT will cause the program to clean up
its /tmp files and stop.

=item *

httpd.perl

This is a test of the nifty POE::Filter::HTTPD module.  The author can
say it's nifty because he didn't write it.  The sample will try
binding to port 80 of INADDR_ANY, but it can be given a new port on
the command line.

=item *

proxy.perl

This is a simple TCP port forwarder.

=item *

ref-type.perl

The "ref-type" sample shows how POE::Filter::Reference can use
specified serialization methods.  It's part of Philip Gwyn's work on
POE::Component::IKC, an XML based RPC package.

=item *

refsender.perl and refserver.perl

These samples use POE::Filter::Reference to pass copies of blessed and
unblessed data between processes.  The standard Storable caveats (such
as its inability to freeze and thaw coderefs) apply.

refserver.perl should be run first, then refsender.  Check refserver's
STDOUT to see what it received.

=item *

thrash.perl

This is a harsh wheel test.  It sets up a simple TCP daytime server
and a pool of clients within the same process.  The clients
continually visit the server, creating and destroying several sockets
a second.  The test will run faster (and thus be harsher on the
system) if it is split into two processes.

=item *

udp.perl

The "udp" sample shows how to create UDP sockets with IO::Socket and
use them in POE.  It was a proof of concept for the SocketFactory
wheel's UDP support.

=item *

watermarks.perl

High and low watermarks are a recent addition to the ReadWrite wheel.
This program revisits the author's good friend, the chargen server,
this time implementing flow control.

Seeing it in action requires a slow client.  Telnet or other raw TCP
clients may work, especially if they are running at maximum niceness.

=item *

wheels.perl

This program is a basic rot13 server.  It was used as an early test
program for the whole Wheel abstraction's premise.

=item *

wheels2.perl

The "wheels2" sample shows how to use separate input and output
filehandles with a wheel.  It's a simple tcp socket client, piping
betwene a socket and stdio.  Stdio is in cooked mode, with all its
caveats.

=back

=head2 Object Layer Examples

As was previously said, the object layer has fallen once again into
disrepair.  However, the olayer.perl sample program illustrates its
current state.

=head2 Proofs of Concepts

These programs are prototypes for strange and wonderful concepts.
They push POE's growth by stretching its capabilities to extrems and
seeing where it hurts.

=over 2

=item *

preforkedserver.perl

This example shows how to write pre-forking servers with POE.  It
tends to dump core after a while, however, due signal issues in Perl,
so it's not recommended as an example of a long running server.

One work-around is to comment out the yield('_stop') calls (there are
two).  These were added to cycle child servers.  The idea was borrowed
from Apache, which only did this to thwart runaway children.  POE
shouldn't leak memory, so churning the children shouldn't be needed.

Still, it is a good test for one of POE's weaknesses.  This thorn in
the author's side will remain enabled.

=item *

tk.perl

The "tk" example is a prototype of POE's Tk support.  It sets up a Tk
main window populated with some buttons and status displays.  The
buttons and displays demonstrate FIFO, alarm and file events in the Tk
environment.

=back

=head1 COMPATIBILITY ISSUES

POE has tested favorably on as many Perl versions as the author can
find or harass people into trying.  This includes Linux, FreeBSD, OS/2
and at least one unspecified version of Windows.  As far as I can
tell, nobody ever has tried it on any version of MacOS.

POE has been tested with Perl versions as far back as 5.004_03 and as
recent as 5.6.0.  The CPAN testers are a wonderful bunch of people who
have dedicated resources to running new modules on a variety of
platforms.  The latest POE tests are visible at
<http://testers.cpan.org/search?request=dist&dist=POE>.  Thanks,
people!

Please let the author know of breakage or success that hasn't been
covered already.  Thanks!

Specific issues:

=over 2

=item *

Various Unices

No known problems.

=item *

OS/2

No known problems.

=item *

Windows

Windows support lapsed in version 0.0806 when I took out some code I
wasn't sure was working.  Well, it was, and removing it broke POE on
Windows.

Douglas Couch reported that POE worked with the latest stable
ActivePerl prior to version 5.6.0-RC1.  He said that RC1 supported
fork and other Unix compatibilities, but it still seemed like beta
level code.  I hope this changed with the release of 5.6.0-GA.

Douglas writes:

  I've done some preliminary testing of the 0.0903 version and the
  re-addition of the Win32 support seems to be a success.  I'll do
  some more intensive testing in the next few days to make sure
  nothing else is broken that I haven't missed.

And later:

  After testing out my own program and having no problems with the
  newest version (with Win32 support), I thought I'd test out some of
  the samples and relay my results.

  filterchange.perl and preforkedserver.perl both contain fork
  commands which are still unsupported by ActiveState's port of Perl,
  so they were both unsuccessful.  (this was anticipated for anything
  containing fork)

  ref-type.perl, refsender.perl, thrash.perl and wheels2.perl all ran
  up against the same unsupported POSIX macro.  According to the error
  message, my vendor's POSIX doesn't support the macro EINPROGRESS.

  [EINPROGRESS is fixed as of version 0.1003; see the Changes]

  Other than those particular problems all of the other sample scripts
  ran fine.

=item *

MacOS

I have heard rumors from MacOS users that POE might work with MacPerl,
but so far nobody has stepped forward with an actual status report.

=back

=head1 SYSTEM REQUIREMENTS

=over 2

=item *

Recommendations

POE would like to see certain functions, but it doesn't strictly
require them.  For example, the sample programs use fork() in a few
places, but POE doesn't require it to run.

If Time::HiRes is present, POE will use it to achieve better accuracy
in its select timeouts.  This makes alarms and delays more accurate,
but POE is designed to work without it as well.

POE includes no XS, and therefore it doesn't require a C compiler.  It
should work wherever a sufficiently complete version of Perl does.

=item *

Hard Requirements

POE requires Filter::Call::Util starting with version 0.1001.  This is
part of the source filter package, Filter, version 1.18 or later.  The
dependency is coded into Makefile.PL, and the CPAN shell can fetch and
install this automatically for you.

POE uses POSIX system calls and constants for portability.  There
should be no problems using it on systems that have sufficient POSIX
support.

Some of POE's sample programs require a recent IO bundle, but you get
that for free with recent versions of Perl.

=item *

Optional Requirements

If you intend to use Filter::Reference, then you will need either the
Storable or FreezeThaw module, or some other freeze/thaw package.
Storable tends to be the fastest, and it's checked first.
Filter::Reference can also use Compress::Zlib upon request, but it's
not required.

Filter::HTTPD requires a small world of modules, including
HTTP::Status; HTTP::Request; HTTP::Date and URI::URL.  The httpd.perl
sample program uses Filter::HTTPD, which uses all that other stuff.

The preforkedserver.perl sample program uses POE::Kernel::fork(),
which in turn requires the fork() built-in function.  This may or may
not be available on your planet.

Other sample programs may require other modules, but the required
modules aren't required if you don't require those specific modules.

=back

=head1 SUPPORT RESOURCES

These are Internet resources where you may find more information about
POE.

=over 2

=item *

The POE Mailing List

POE has a mailing list thanks to Artur Bergman and Vogon Solutions.
You may subscribe to it by sending e-mail:

  To: poe-help@vogon.se
  Subject: (anything will do)

  Anything will do for the message body.

All forms of feedback are welcome.

=item *

POE has a web site thanks to Johnathan Vail.  The latest POE
development snapshot, along with the Changes file and some other stuff
can be found at <http://www.newts.org/~troc/poe.html>.

=back

=head1 SEE ALSO

This is a summary of POE's modules.

=over 2

=item *

Events Layer

POE::Kernel; POE::Session

=item *

I/O Layer

POE::Driver; POE::Driver::SysRW

POE::Filter; POE::Filter::HTTPD; POE::Filter::Line;
POE::Filter::Reference; POE::Filter::Stream

POE::Wheel; POE::Wheel::FollowTail; POE::Wheel::ListenAccept;
POE::Wheel::ReadWrite; POE::Wheel::SocketFactory

=item *

Object Layer

These modules are in limbo at the moment.

POE::Curator; POE::Object; POE::Repository; POE::Attribute::Array;
POE::Runtime

=item *

Components

POE::Component; POE::Component::Server::TCP

=item *

Supporting cast

POE::Preprocessor

=back

=head1 BUGS

The Object Layer is still in early design, so it's not documented yet.

There need to be more automated regression tests in the t/*.t
directory.  Please suggest tests; the author is short on ideas here.

The documentation is in the process of another revision.  Here is a
progress report:

  POE                          rewritten 2000.05.15
  README                       rewritten 2000.05.16
  POE::Kernel                  rewritten 2000.05.19
  POE::Session                 rewritten 2000.05.21
  POE::Wheel                   rewritten 2000.05.22
  POE::Preprocessor            revised   2000.05.23

  POE::Component               queued
  POE::Component::Server::TCP  queued
  POE::Driver                  queued
  POE::Driver::SysRW           queued
  POE::Filter                  queued
  POE::Filter::Block           queued
  POE::Filter::HTTPD           queued
  POE::Filter::Line            queued
  POE::Filter::Reference       queued
  POE::Filter::Stream          queued
  POE::Wheel::FollowTail       queued
  POE::Wheel::ListenAccept     queued
  POE::Wheel::ReadWrite        queued
  POE::Wheel::SocketFactory    queued

=head1 AUTHORS & COPYRIGHT

POE is the combined effort of more people than I can remember
sometimes.  If I've forgotten someone, please let me know.

=over 2

=item *

Addi

Addi is <e-mail unknown>.

Addi has tested POE and POE::Component::IRC on the Windows platform,
finding bugs and testing fixes.  You'll see his name sprinkled
throughout the Changes file.

=item *

Artur Bergman

Artur Bergman is <artur@vogon-solutions.com>.

Artur has contributed many hours and ideas.  He's also the author of
Filter::HTTPD and Filter::Reference, as well as bits and pieces
throughout POE.  His intangible contributions include feedback,
testing, conceptual planning and inspiration.  POE would never have
come this far without his support.

=item *

Douglas Couch

Douglas Couch is <dscouch@purdue.edu>

Douglas was the brave soul who stepped forward to offer valuable
testing on the Windows platforms.  His reports helped get POE working
on Win32 and are summarized earlier in this document.

=item *

Philip Gwyn

Philip Gwyn is <gwynp@artware.qc.ca>.

Philip extended the Wheels I/O abstraction to allow filters to be
changed at runtime and provided patches to add the eminently cool
Kernel and Session IDs.  He also enhanced Filter::Reference to support
different serialization methods.  His intangible contributions include
the discovery and/or destruction of several bugs (see the Changes
file) and a thorough code review around version 0.06.

=item *

Dave Paris

Dave Paris is <dparis@w3works.com>.  He often goes by the nickname
"a-mused".

Dave tested and benchmarked POE around version 0.05, discovering some
subtle (and not so subtle) timing problems.  The pre-forking server
was his idea.  Versions 0.06 and later should scale to higher loads
because of his work.  His intangible contributions include lots of
testing and feedback, some of which is visible in the Changes file.

=item *

Dieter Pearcey is <dieter@bullfrog.perlhacker.org>.  He goes by
several Japanese nicknames.

Dieter patched Wheel::FollowTail to be more useful and has contributed
the basic Filter::Block, along with documentation!

=item *

Robert Seifer

Robert Seifer is <e-mail unknown>.  He rotates IRC nicknames
regularly.

Robert contributed entirely too much time, both his own and his
computers, towards the detection and eradication of a memory
corruption bug that POE tickled in earlier Perl versions.  In the end,
his work produced a simple compile-time hack that worked around a
problem relating to anonymous subs, scope and @{} processing.

=item *

Others?

Anyone who has been forgotten, please contact me.

=back

=head2 Author

=over 2

=item *

Rocco Caputo

Rocco Caputo is <troc+poe@netrus.net>.  POE is his brainchild.

Except where otherwise noted, POE is Copyright 1998-2000 Rocco Caputo.
All rights reserved.  POE is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=back

Thank you for reading!

=cut
