# $Id$
# Copyrights and documentation are after __END__.

package POE;

use strict;
use Carp;

use vars qw($VERSION);
$VERSION = '0.2303';

sub import {
  my $self = shift;

  my @sessions = grep(/^(Session|NFA)$/, @_);
  my @modules = grep(!/^(Kernel|Session|NFA)$/, @_);

  croak "POE::Session and POE::NFA export conflicting constants"
    if grep(/^(Session|NFA)$/, @sessions) > 1;

  # Add Kernel back it, whether anybody wanted it or not.
  unshift @modules, 'Kernel';

  # If a session was specified, use that.  Otherwise use Session.
  if (@sessions) {
    unshift @modules, @sessions;
  }
  else {
    unshift @modules, 'Session';
  }

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

POE - multitasking and networking framework for perl

=head1 SYNOPSIS

  #!/usr/bin/perl -w
  use strict;

  # Use POE!
  use POE;

  sub handler_start {
    my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
    print "Session ", $session->ID, " has started.\n";
    $heap->{count} = 0;
    $kernel->yield('increment');
  }

  sub handler_increment {
    my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
    print "Session ", $session->ID, " counted to ", ++$heap->{count}, ".\n";
    $kernel->yield('increment') if $heap->{count} < 10;
  }

  sub handler_stop {
    print "Session ", $_[SESSION]->ID, " has stopped.\n";
  }

  for (0..9) {
    POE::Session->create(
      inline_states =>
        { _start    => \&handler_start,
          increment => \&handler_increment,
          _stop     => \&handler_stop,
        }
    );
  }

  $poe_kernel->run();
  exit;

=head1 QUICK LINKS

Please see the SEE ALSO section for conceptual summary of all POE's
documentation.

POE's distribution comes with a directory full of examples, but they
are gradually being phased out in favor of an online "cookbook".
Please see the samples directory, and also look at
http://poe.perl.org/?POE_Cookbook for more contemporary examples.

Please see http://www.perl.com/pub/2001/01/poe.html for an excellent,
and more importantly: gradual, introduction to POE.  If this manpage
doesn't make sense, perhaps the introduction will.

Please see POE's web site at http://poe.perl.org/ for FAQs, cookbook
examples, and modules using POE.

=head1 DESCRIPTION

POE is an acronym of "Perl Object Environment".  It originally was
designed as the core of a persistent object server and runtime
environment, but it's evolved into a general purpose multitasking and
networking framework.

POE's core contains two types of modules.  First there's POE::Kernel;
this is the main resource manager and event loop.  Second are the
sessions or state machines which implement the actual threads.  The
sessions are POE::Session (not quite a proper state machine) and
POE::NFA.

The remainder of this distribution consists of convenience and helper
modules, most of which aren't required to begin using POE.

=head1 USING POE

Using POE can be pretty tedious.  Consider this example, which pulls
in the necessary modules for a line-based TCP server:

  use POE::Kernel;
  use POE::Session;
  use POE::Wheel::SocketFactory;
  use POE::Wheel::ReadWrite;
  use POE::Filter::Line;
  use POE::Driver::SysRW;

The POE.pm module fixes some of this tedium.  When POE.pm is used
directly, it automatically includes POE::Kernel and POE::Session.  It
also includes each of the C<use> statement's parameters, first
prepending "POE::" to them.  An example is in order:

This C<use> statement is equivalent to the previous six.

  use POE qw( Wheel::SocketFactory Wheel::ReadWrite
              Filter::Line Driver::SysRW
            );

=head1 WRITING POE PROGRAMS

Basic POE programs have four parts.

=over 2

=item Preliminary program setup

This is the usual overhead for writing a Perl program: a shebang line,
perhaps some C<use> statements to import things, and maybe some global
variables or configuration constants.  It's all pretty standard stuff.

  #!/usr/bin/perl -w
  use strict;
  use POE;

=item Define the program's event handlers or states

Declare functions which will handle events here.  This is deceptive,
since the functions can be declared anywhere, including as anonymous
subroutines in a session constructor call.

  sub handler_start {
    ...
  }

  sub handler_increment {
    ...
  }

  sub handler_stop {
    ...
  }

=item Start initial sessions or machines

The Kernel only runs as long as there is something for it to do.  It's
main loop returns after the last session has stopped.  The obvious
corolary to this rule is that the main loop will return immediately if
nothing is set up when it's called.

  for (0..9) {
    POE::Session->create(
      inline_states =>
        { _start    => \&handler_start,
          increment => \&handler_increment,
          _stop     => \&handler_stop,
        }
    );
  }

=item Start the kernel's main loop

_start handlers are invoked immediately when sessions are
instantiated.  Everything else happens because the kernel makes it so,
and the kernel can't do that 'til it's started.  Most programs exit
afterwards since the kernel only returns after everything is done.

  $poe_kernel->run();
  exit 0;

=back


=head1 POE's ARCHITECTURE

POE is built in separate layers.  Each layer requires the ones beneath
it, but no low-level layer requires a higher one.

=over 2

=item Events layer

The events layer consists of an event dispatcher, POE::Kernel, and the
sessions or state machines it runs: POE::Session (a generic event
driven thread) and POE::NFA (an event driven nondeterministic finite
automaton).

=item One or more I/O layers

I/O layers are built upon the event layer, and that allows them to
coexist in the same program.  POE only includes one I/O layer: Wheels.
"Wheels" is a whimsical name for interlocking cogs that together make
things go.  They're also reinvented a lot, and this is no exception.

POE comes with six wheels.

=over 2

=item POE::Wheel::Curses

The Curses wheel handles non-blocking input for programs using the
curses text interface.  It requires the Curses perl module and a
familiarity with curses programming.q

=item POE::Wheel::FollowTail

FollowTail follows the tail of an ever-growing file.  It's useful for
watching logs and things of that nature.

=item POE::Wheel::ListenAccept

ListenAccept performs ye olde non-blocking socket listen and accept.
It's great for programs that can't use SocketFactory and instead must
listen and accept connections from sockets created elsewhere.

=item POE::Wheel::ReadLine

The ReadLine wheel accepts console input as lines only.  It handles
many of the common shell command editing keystrokes, making it pretty
easy to input things.  It's event driven, unlike Term::ReadLine, and
it cooperates nicely with the rest of POE.

=item POE::Wheel::ReadWrite

ReadWrite is the star of POE's default I/O layer.  It performs
buffered, flow-controlled I/O on non-blocking, unbuffered filehandles.
It almost acts like a Unix stream which can't stack protocol layers,
but that may change.

ReadWrite uses two other classes to do its dirty work: Driver and
Filter.  Drivers do the actual work of reading and writing
filehandles.  Filters translate between raw streams and cooked chunks
of tasty dada.

D comes before F, so Drivers go first.

=over 2

=item POE::Driver::SysRW

Nobody has needed another driver yet, so this is the only one
currently available.  It performs sysread and syswrite in a generic
way so that ReadWrite can use it and future drivers interchangeably.

Other drivers will use the same interface, should they ever be
written.

=back

Filters next.  There are a few.

=over 2

=item POE::Filter::Block

This filter parses input as fixed-length blocks.  On the output side,
it merely passes data through unscathed.

=item POE::Filter::HTTPD

The HTTPD filter parses input as HTTP requests and translates them
into HTTP::Request objects.  On the output side, it takes
HTTP::Response objects and turns them into something suitable to be
sent to a web client/user-agent.

=item POE::Filter::Line

The Line filter parses incoming streams into lines and turns outgoing
lines into streams.  It used to be very basic, but recent improvements
have added interesting features like newline autodetection.

=item POE::Filter::Reference

The Reference filter is used to send Perl structures between POE
programs or between POE and other Perl programs.  On the input side,
frozen data (via Storable, FreezeThaw, YAML, or some other data
mechanism) is thawed into Perl data structures.  On output, references
given to the filter are frozen.  Data may also be compressed on
request if Compress::Zlib is installed.

=item POE::Filter::Stream

The stream filter does nothing.  It merely passes data through without
any change.

=back

=item POE::Wheel::Run

The Run wheel provides a way to run functions or other programs in
child processes.  It encapsulates the necessary pipe() and fork()
code, and sometimes exec().  Internally, it handles reading from and
writing to child processes without further intervention.  Child output
arrives in the Wheel's owner as events.

=item POE::Wheel::SocketFactory

SocketFactory creates all manner of connectionless and connected
network sockets.  It also listens on TCP server sockets, only
returning accepted client connections as they arrive.

=back

=back

=head1 POE COMPONENTS

Components consist of one or more sessions or state machines that
encapsulate a very high level procedure.  For example,
POE::Component::IRC (not included) performs nearly all the functions
of a full-featured IRC client.  POE::Component::UserBase (not
included) is a user authentication and data persistence servlet.

Components tend to be highly reusable libraries that handle tedious
tasks, freeing programmers to focus on more interesting things.  This
should be true for any library, though.

A list of released POE::Component modules is at:
http://search.cpan.org/search?mode=module&query=POE%3A%3AComponent

=over 2

=item POE::Component::Client::TCP

The Client::TCP component provides the most common core features for
writing TCP clients.

=item POE::Component::Server::TCP

The Server::TCP component provides the most common core features for
writing TCP servers.  A simple echo server is about 20 lines.

=head1 Support Modules

Finally, there are some files which POE uses but aren't required
elsewhere.  These include POE::Preprocessor and the base classes:
POE::Component, POE::Driver, POE::Filter and POE::Wheel.  There also
are some development files in the lib directory.

=over 2

=item POE::Preprocessor

This is a macro preprocessor.  It also implements plain and enumerated
constants.  POE::Kernel uses it to inline smaller functions and make
the source generally more readable.  There seem to be two drawbacks:
First, code is more difficult to examine in perl's debugger since it
doesn't necessarily look like the original source.  Second, programs
take longer to start up because every source line must first pass
through a perl filter.  The compile-time penalty is negligible in
long-running programs, and the runtime boost from fewer function calls
can make up for it over time.

POE::Component, POE::Driver and POE::Filter exist to document their
classes of objects.  POE::Wheel contains some base functions for
tracking unique wheel IDs.

=head1 SAMPLE PROGRAMS

This distribution contains several example and/or tutorial programs in
the ./samples directory.  Be advised, however, that they are old and
may not exhibit the most current coding practices.

The sample programs are scheduled for removal from this distribution
in version 0.1301.  They are being moved to the web version of the POE
Cookbook, which is available at <http://poe.perl.org/?POE_Cookbook>.

The author is always looking for new example ideas.

=head1 COMPATIBILITY ISSUES

POE has tested favorably on as many Perl versions as the author can
find or harass people into trying.  This includes Linux, FreeBSD, OS/2
and at least one unspecified version of Windows.  As far as anyone can
tell, nobody ever has tried it on any version of MacOS.

POE has been tested with Perl versions as far back as 5.004_03 and as
recent as 5.7.2.  The CPAN testers are a wonderful bunch of people who
have dedicated resources to running new modules on a variety of
platforms.  The latest POE tests are visible at
<http://testers.cpan.org/search?request=dist&dist=POE>.  Thanks,
people!

Please let the author know of breakage or success that hasn't been
covered already.  Thanks!

Specific issues:

=over 2

=item Various Unices

No known problems.

=item OS/2

No known problems.  POE has no OS/2 tester starting with version
0.1206.

=item Windows

POE seems to work very nicely with Perl compiled for CygWin.  If you
must use ActiveState Perl, please use build 631 or newer.

Currently there is nobody maintaining POE for Windows.  Rocco will be
fixing things as he's able, but he has only limited access to Windows
machines for testing and development.  If you would like to accelerate
POE's Windows support, please contact Rocco or the mailing list.

Thanks to Sean Puckett, Douglas Couch, Hachi, and Dynweb for their
help in bringing POE's Windows support so far.

=item MacOS

POE 0.18 passes all tests on MacOS/X.

Its pre-X support seems like a lost cause unless someone steps forward
to make it happen.

=back

=head1 SYSTEM REQUIREMENTS

POE requires Filter::Util::Call version 1.18 or newer.  All the other
modules are optional.

Time::HiRes is recommended.

Some of POE's sample programs use fork().  They won't work wherever
fork() isn't available; sorry.

POE relies heavily on constants in the POSIX module.  Some of the
constants aren't defined on some platforms.  POE works around this as
best it can.

Some of POE's sample programs require a recent IO bundle, but you get
that for free with recent versions of Perl.

If you want to use Filter::Reference to serialize data for
transporting over a network, you will need Storable, FreezeThaw, or
some other freezer/thawer package installed.  If you want your data to
be shipped compressed, you will also need Compress::Zlib.

B<Important Filter::Reference note:> If you're using Filter::Reference
to pass data to another machine, make sure every machine has the same
versions of the same libraries.  Subtle differences, even in different
versions of modules like Storable, can cause mysterious errors when
data is reconstituted at the receiving end.  Whe all else fails,
upgrade to the latest versions.

Filter::HTTPD uses a small world of modules including HTTP::Status;
HTTP::Request; HTTP::Date and URI::URL.  The httpd.perl sample program
uses Filter::HTTPD, which uses all that other stuff.  If you want to
write web servers, you'll need to install libwww-perl, which requires
libnet.

Wheel::Curses requires the Curses module, which in turn requires some
sort of curses library.

=head1 SUPPORT RESOURCES

These are Internet resources where you may find more information about
POE.

=over 2

=item The POE Mailing List

POE has a mailing list at perl.org.  You can receive subscription
information by sending e-mail:

  To: poe-help@perl.org
  Subject: (anything will do)

  The message body is ignored.

All forms of feedback are welcome.

=item The POE Web Site

POE has a web site where the latest development snapshot, along with
the Changes file and other stuff may be found: http://poe.perl.org/

=item SourceForge

POE's development has moved to SourceForge as an experiment in project
management.  You can reach POE's project summary page at
http://sourceforge.net/projects/poe/

=back

=head1 SEE ALSO

This is a summary of POE's modules and the things documented in each.

=head2 Events Layer

These are POE's core modules.

=over 2

=item POE (this document)

The POE manpage includes a sample program and walkthrough of its
parts, a summary of the modules which comprise this distribution,
POE's general system requirements, how to use POE (literally), and
where to get help.  It also has a table of contents which you're even
now reading.

=item POE::Kernel

The POE::Kernel manpage includes information about debugging traces
and assertions; FIFO events; filehandle watchers; Kernel data
accessors; posting events from traditional callbacks (postbacks);
redefining sessions' states; resource management; session aliases;
signal types, handlers, and pitfalls; signal watchers; synchronous
vs. asynchronous events; and timed events (alarms and delays).

=item POE::NFA

The POE::NFA manpage covers this session's additional predefined
events, how NFA differs from Session, state changing methods, and the
spawn constructor.

=item POE::Session

The POE::Session manpage covers different kinds of states (inline
coderef, object methods, and package methods); postback mechanics;
predefined event names and the parameters included with them; resource
management and its effects on sessions; session constructors (new and
create); session data accessors; synchronous vs. asynchronous events
in more detail; why sessions don't stop by themselves, and how to
force them to.

=back

=head2 I/O Layer

These modules comprise POE's default I/O abstraction.

=over 2

=item POE::Driver

The POE::Driver manpage covers drivers in general and their common
interface.

=item POE::Driver::SysRW

The SysRW driver's manpage describes the sysread/syswrite abstraction
and covers parameters which can be used to customize a SysRW driver's
operation.

=item POE::Filter

The POE::Filter manpage covers filters in general and their common
interface.  It discusses the pitfalls involved in switching filters
on a running wheel.

=item POE::Filter::Grep

Grep is part of the family of filters that includes Stackable, Map,
and RecordBlock.  It applies a regexp filter on data passing through
it, before it reaches a Session.  It's mainly used in filter stacks
(see POE::Filter::Stackable).

=item POE::Filter::HTTPD

The HTTPD filter's manpage covers using POE as a web server.

=item POE::Filter::Line

The Line filter's manpage discusses how to read and write data by
lines; how to change the newline literal or regular expression; and
how to enable newline autodetection when working with strange peers.

=item POE::Filter::Map

Map is part of the family of filters that includes Stackable, Grep,
and RecordBlock.  It transforms data passing through it, before it
reaches a Session.

The Map filter is designed primarily to act as an interface between
filters that deal with different data formats, but it can be used
stand-alone to perform unique functions that no other filter does.  In
this case it's something of a wildcard filter.

If you find yourself reusing the same custom Map filter, you may want
to turn it into a full-fledged filter.

=item POE::Filter::RecordBlock

RecordBlock combines records into groups by count and flattens groups
of records back into a record stream.  For example, RecordBlock might
combine log records into pairs.

=item POE::Filter::Reference

The Reference filter's manpage talks about marshalling data and
passing it between POE programs; and customizing the way data is
frozen, thawed and optionally compressed.

=item POE::Filter::Stackable

Stackable is a meta-filter designed to stack other filters.  Stackable
manages the filters it contains and passes data between them.  In
essence, the inner filters are combined into one super filter.

The Map filter can also be used to perform quick and dirty functions
that aren't implemented in any single existing filter.

=item POE::Filter::Stream

The Stream filter's manpage is pretty empty since it doesn't do much
of anything.

=item POE::Wheel

The Wheel's manpage talks about wheels in general and their common
interface.

=item POE::Wheel::FollowTail

The FollowTail wheel's manpage discusses how to watch the end of an
ever-growing file (not to be confused with that orb tune) and how to
change aspects of the wheel's behavior with constructor parameters.

=item POE::Wheel::ListenAccept

The ListenAccept wheel's manpage discusses how to listen and accept
connections using sockets created from sources other than
SocketFactory.

=item POE::Wheel::ReadWrite

The ReadWrite wheel's manpage covers non-blocking I/O with optional
flow control.

=item POE::Wheel::SocketFactory

The SocketFactory wheel's manpage discusses how socket factories
create and manage sockets; the events they emit on connection,
acceptance, and failure; and the parameters which govern what they do.

=back

=head2 Standard Components

These components are included with POE because they're nearly
universally useful.

=over 2

=item POE::Component

The POE::Component manpage discusses what components are and why they
exist.

=item POE::Component::Client::TCP

The TCP client component explains how to create TCP clients quickly
and easily.

=item POE::Component::Server::TCP

The TCP server component explains how to create TCP servers with a
minimum of fuss.

=back

=head2 Supporting Cast

These modules help in the background.

=over 2

=item POE::Pipe::OneWay

This creates unbuffered one-way pipes.  It tries various methods in
the hope that one of them will work on any given platform.

=item POE::Pipe::TwoWay

This creates unbuffered two-way pipes.  It tries various methods in
the hope that one of them will work on any given platform.  It's
preferred over two OneWay pipes because sometimes two-way transports
are available and it can save you a couple filehandles.

=item POE::Preprocessor

POE's preprocessor covers inline constant replacement, enumerated
constants, and macro substitutions in perl programs.

=back

=head1 BUGS

The t/*.t tests only cover about 70% of POE.  The latest numbers are
on POE's web site.

=head1 AUTHORS & COPYRIGHT

POE is the combined effort of several people.  If someone is missing
from this list, please let Rocco know.

=over 2

=item Ann Barcomb

Ann Barcomb is <kudra@domaintje.com>, aka C<kudra>.  Ann contributed
large portions of POE::Simple and the code that became the ReadWrite
support in POE::Component::Server::TCP.  Her ideas also inspired
Client::TCP component, introduced in version 0.1702.

=item Artur Bergman

Artur Bergman is <artur@vogon-solutions.com>.  He contributed many
hours' work into POE and quite a lot of ideas.  Years later, I decide
he's right and actually implement them.

Artur is the author of Filter::HTTPD and Filter::Reference, as well as
bits and pieces throughout POE.  His intangible contributions include
feedback, testing, conceptual planning and inspiration.  POE would
never have come this far without his support.

Artur is investing his time heavily into perl 5's ithreads at the
moment.  This project has far-reaching implications for POE's future.

=item Jos Boumans

Jos Boumans is <boumans@frg.eur.nl>, aka C<Co-Kane>.  Jos is a major
driving force behind the POE::Simple movement and is one of the POE
idea fairies.  Jos is working with Ann on POE::Simple.

=item Matt Cashner

Matt Cashner is <eek@eekeek.org>, aka C<sungo>.  Matt is a POE
ambassador, or something, between Rocco's point of view and people who
haven't had the benefit of knowing the system since its conception.
He's spearheaded the movement to smiplify POE for new users,
flattening the learning curve and making the system more accessible to
everyone.  He's almost singlehandedly rewriting POE's documentation.
He uses the system in mission critical applications, folding feedback
and features back into the distribution for everyone's enjoyment.

=item Andrew Chen

Andrew Chen is <achen-poe@micropixel.com>.  Andrew is the resident
POE/Windows guru.  He contributes much needed testing for Solaris on
the SPARC and Windows on various Intel platforms.

=item Douglas Couch

Douglas Couch is <dscouch@purdue.edu>.  Douglas maintains POE's PPD
for Windows as well as up-to-date online documentation at
http://poe.sourceforge.net/

=item Jeffrey Goff

Jeffrey Goff is <jgoff@blackboard.com>.  Jeffrey is the author of
several POE modules, including a tokenizing filter and a component for
managing user information, PoCo::UserBase.  He's also co-author of "A
Beginner's Introduction to POE" at www.perl.com.

=item Philip Gwyn

Philip Gwyn is <gwynp@artware.qc.ca>.  He extended the Wheels I/O
abstraction to support hot-swappable filters, and he eventually
convinced Rocco that unique session and kernel IDs were a good thing.

Philip also enhanced Filter::Reference to support different
serialization methods.  His intangible contributions include the
discovery and/or destruction of several bugs (see the Changes file)
and a thorough code review around version 0.06.

=item Arnar M. Hrafnkelsson

Arnar is <addi@umich.edu>.  Addi tested POE and POE::Component::IRC on
Windows, finding bugs and testing fixes.  He appears throughout the
Changes file.

=item Dave Paris

Dave Paris is <dparis@w3works.com>.  Dave tested and benchmarked POE
around version 0.05, discovering some subtle (and not so subtle)
timing problems.  The pre-forking server sample was his idea.
Versions 0.06 and later should scale to higher loads because of his
work.  He has contributed a lot of testing and feedback, much of which
is tagged in the Changes file as a-mused.

And I do mean *lots* of testing.  I go and announce a new development
version, and he's, like, "All tests passed!" just a few minutes later.
If that wasn't enough, he investigates any bugs that turn up, and
often fixes them.  The man's scarily good.

=item Dieter Pearcey

Dieter Pearcey is <dieter@bullfrog.perlhacker.org>.  He goes by
several Japanese nicknames.  Dieter's current area of expertise is in
Wheels and Filters.  He greatly improved Wheel::FollowTail, and his
Filter contributions include the basic Block filter, as well as
Stackable, RecordBlock, Grep and Map.

=item Robert Seifer

Robert Seifer is <e-mail unknown>.  He rotates IRC nicknames
regularly.

Robert contributed entirely too much time, both his own and his
computers, towards the detection and eradication of a memory
corruption bug that POE tickled in earlier Perl versions.  In the end,
his work produced a simple compile-time hack that worked around a
problem relating to anonymous subs, scope and @{} processing.

=item Matt Sergeant

Matt contributed POE::Kernel::Poll, a more efficient way to watch
multiple files than select().

=item Richard Soderberg

Richard Soderberg is <poe@crystalflame.net>, aka C<coral>.  Richard is
a collaborator on several side projects involving POE.  His work
provides valuable testing and feedback from a user's point of view.

=item Dennis Taylor

Dennis Taylor is <dennis@funkplanet.com>.  Dennis has been testing,
debugging and patching bits here and there, such as Filter::Line which
he improved by leaps in 0.1102.  He's also the author of
POE::Component::IRC.

=item Others?

Please contact the author if you've been forgotten.

=back

=head2 Author

=over 2

=item Rocco Caputo

Rocco Caputo is <rcaputo@cpan.org>.  POE is his brainchild.

Except where otherwise noted, POE is Copyright 1998-2002 Rocco Caputo.
All rights reserved.  POE is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=back

Thank you for reading!

=cut
