# $Id$
# Copyrights and documentation are after __END__.

package POE;

use strict;
use Carp qw( croak );

use vars qw($VERSION $REVISION);
$VERSION = '0.33';
$REVISION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

sub import {
  my $self = shift;

  my @loops    = grep(/^Loop\:\:/, @_);
  my @sessions = grep(/^(Session|NFA)$/, @_);
  my @modules  = grep(!/^(Kernel|Session|NFA|Loop)$/, @_);

  croak "can't use multiple event loops at once"
    if (@loops > 1);
  croak "POE::Session and POE::NFA export conflicting constants"
    if grep(/^(Session|NFA)$/, @sessions) > 1;

  # If a session was specified, use that.  Otherwise use Session.
  if (@sessions) {
    unshift @modules, @sessions;
  }
  else {
    unshift @modules, 'Session';
  }

  my $package = caller();
  my @failed;

  # Load POE::Kernel in the caller's package.  This is separate
  # because we need to push POE::Loop classes through POE::Kernel's
  # import().

  {
    my $loop = "";
    if (@loops) {
      $loop = "{ loop => '" . shift (@loops) . "' }";
    }
    my $code = "package $package; use POE::Kernel $loop;";
    # warn $code;
    eval $code;
    if ($@) {
      warn $@;
      push @failed, "Kernel"
    };
  }

  # Load all the others.

  foreach my $module (@modules) {
    my $code = "package $package; use POE::$module;";
    # warn $code;
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

POE - portable multitasking and networking framework for Perl

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

  for (1..10) {
    POE::Session->create(
      inline_states => {
        _start    => \&handler_start,
        increment => \&handler_increment,
        _stop     => \&handler_stop,
      }
    );
  }

  POE::Kernel->run();
  exit;

=head1 DESCRIPTION

POE is a framework for cooperative, event driven multitasking in Perl.
Other languages have similar frameworks.  Python has Twisted.  TCL has
"the event loop".

POE originally was developed as the core of a persistent object server
and runtime environment.  It has evolved into a general purpose
multitasking and networking framework, encompassing and providing a
consistent interface to other event loops such as Event and the Tk and
Gtk toolkits.

POE is written in layers, each building upon the previous.  It's
therefore possible to use POE at varying levels of abstraction.

The lowest level uses POE::Kernel and POE::Session.  The former class
acts as POE's event watcher and dispatcher.  The latter encapsulates
the notion of an event driven task.

POE::Wheel classes operate at a slightly higher level.  They plug into
sessions and perform very common, general tasks.  For example,
POE::Wheel::ReadWrite performs buffered I/O.  

Unlike cheese, wheels do not stand alone.  They are customized by
POE::Driver and POE::Filter classes.  Using the proper filter, a
ReadWrite wheel can read and write streams, lines, fixed-length
blocks, HTTP requests and responses, and so on.

The highest level of POE programming uses components.  They may
perform narrowly defined tasks, such as POE::Component::Child (on the
CPAN).  Often they encapsulate nearly everything necessary for an
entire program.

Every level eventually boils down to the lowest common
denominator---POE::Kernel and POE::Session.  Because of this, classes
coexist and cooperate at every level of abstraction.

=head1 DOCUMENTATION ROADMAP

POE's documentation rewards the methodical reader.  Skim everything,
and you should have a pretty good idea of what's available and where
to find it later.

You're reading the main POE document.  It's the general entry point to
POE's documentation.

Documentation for POE's basic features is spread across POE::Kernel
and POE::Session in non-intuitive ways.  POE turns out to be difficult
to document from either module's perspective, so there is a lot of
overlap and cross-referencing.  We have plans to rewrite them, but
that only helps if you want to join in the fun.

POE::NFA is a second kind of session---a Non-deterministic Finite
Automaton class, which happens to be driven by events.  This is an
abstract state machine, which can be either Mealy or Moore (or a
little bit of both, or neither) depending on how it's configured.

POE::Wheel, POE::Driver, POE::Filter, and POE::Component describe
entire classes of modules in broad strokes.  Where applicable, they
document the features common among their subclasses.  This is
confusing, since most people are inclined to read POE::Wheel::Foo and
assume that something doesn't exist if it's not there.

There are also some helper classes.  POE::Pipe is the base class for
POE::Pipe::OneWay and POE::Pipe::TwoWay.  They are portable pipe
creation functions, mainly for POE's test suite.  POE::Preprocessor is
a macro language implemented as a source filter.

POE is a relatively large system.  It includes internal classes that
allow it to be customized without needing to know too much about the
system as a whole.  POE::Queue describes POE's event queue interface.
POE::Loop covers the commonalities of every event loop POE supports.
POE::Resource discusses the notion of system resources, which
correspond to event watchers and generators in other systems.

The SEE ALSO sections of each major module class will list the
subclasses beneath it.  This document's SEE ALSO lists every module in
the distribution.

Finally, there are many POE resources on the web.  The CPAN contains a
growing number of POE modules.  POE's wiki, at
L<http://poe.perl.org/>, includes tutorials, an extensive set of
examples, documentation, and more.

=head1 COMPATIBILITY ISSUES

The developers of POE strive to make it as portable as possible.  If
you discover a problem, please e-mail a report to
<bug-POE@rt.cpan.org>.  If you can, include error messages, C<perl -V>
output, and/or test cases.  The more information you can provide, the
quicker we can turn around a fix.  Patches are also welcome, of
course.

POE is known to work on FreeBSD, MacOS X, Linux, Solaris, and other
forms of UNIX.  It also works to one extent or another on various
versions of Windows, including 98, ME, NT, 2000, and XP.  It should
work on OS/2, although we no longer have a developer who uses it.  It
has been reported to work on MacOS 9, of all things.

POE has been tested with Perl versions as far back as 5.004_03 and as
recent as 5.8.3.

Thanks go out to the CPAN testers, who have dedicated resources to
running new modules on a variety of platforms.  The latest POE tests
are visible at <http://testers.cpan.org/search?request=dist&dist=POE>.

We maintain our own test results at <http://eekeek.org/poe-tests/>.
You may participate by running

  perl Makefile.PL
  make uploadreport

from POE's source directory.  A set of tests will be run, and their
results will be uploaded to our test page.

We also try to cover all of POE with our test suite, although we only
succeed in exercising about 70% of its code at any given time.  A
coverage report is online at
<http://poe.perl.org/?POE's_test_coverage_report>.

Specific issues:

=over 2

=item Various Unices

No known problems.

=item OS/2

No known problems.  POE has no OS/2 tester as of version 0.1206.

=item Windows

POE seems to work very nicely with Perl compiled for Cygwin.  If you
must use ActiveState Perl, please use the absolute latest version.
ActiveState Perl's compatibility fluctuates from one build to another,
so we only support the most recent build prior to POE's release.

POE's Windows port is current maintained by Rocco Caputo, but he has
only limited knowledge of Windows development.  Please contact Rocco
if you or someone you know would like to accelerate POE's Windows
support.

A number of people have helped bring POE's Windows support this far,
through contributions of time, patches, and other resources.  Some of
them are: Sean Puckett, Douglas Couch, Andrew Chen, Uhlarik Ondoej,
and Nick Williams.

TODO: I'm sure there are others.  Find them in the changelog and thank
them here.

=item MacOS

No known problems on MacOS X.

Mac Classic (versions 9.x and before) was reported to work at one
time, but it seems like a lost cause unless someone would like to step
forward and make it happen.

=back

=head1 SYSTEM REQUIREMENTS

POE's installer will prompt for required and optional modules.  It's
important to read the prompts and only install what you will need.
You may always reinstall it later, adding new prerequisites as the
need arises.

Time::HiRes is recommended.  POE will work without it, but alarms and
other features will be much more accurate with it.

POE relies heavily on constants in the POSIX module.  Some of the
constants aren't defined on some platforms.  POE works around this as
best it can, but problems occasionally crop up.  Please let us know if
you run into problems, and we'll work with you to fix them.

Filter::Reference needs a module to serialize data for transporting it
across a network.  It will use Storable, FreezeThaw, YAML, or some
other package with freeze() and thaw() methods.  It can also use
Compress::Zlib to conserve bandwidth and reduce latency over slow
links, but it's not required.

If you want to write web servers, you'll need to install libwww-perl,
which requires libnet.  This is a small world of modules that includes
HTTP::Status, HTTP::Request, HTTP::Date, and HTTP::Response.  They are
generally good to have, and recent versions of Perl include them.

Programs that use Wheel::Curses require the Curses module, which in
turn requires some sort of curses library.

=head1 SUPPORT RESOURCES

These are Internet resources where you may find more information about
POE.

=over 2

=item POE's Mailing List

POE has a mailing list where you can discuss it with the community at
large.  You can receive subscription information by sending e-mail to:

  To: poe-help@perl.org
  Subject: (anything will do)

The message body is ignored.

=item POE's Web Site

POE's web site contains the latest development snapshot along with
examples, tutorials, and other fun stuff.  It's at
<http://poe.perl.org/>.

=item SourceForge

POE is developed at SourceForge.  The project is hosted at
http://sourceforge.net/projects/poe/

=back

=head1 SEE ALSO

POE::Kernel, POE::Session, POE::NFA

POE::Wheel, POE::Wheel::Curses, POE::Wheel::FollowTail,
POE::Wheel::ListenAccept, POE::Wheel::ReadLine, POE::Wheel::ReadWrite,
POE::Wheel::Run, POE::Wheel::SocketFactory

POE::Driver, POE::Driver::SysRW

POE::Filter, POE::Filter::Block, POE::Filter::Grep,
POE::Filter::HTTPD, POE::Filter::Line, POE::Filter::Map,
POE::Filter::RecordBlock, POE::Filter::Reference,
POE::Filter::Stackable, POE::Filter::Stream

POE::Component, POE::Component::Client::TCP,
POE::Component::Server::TCP

POE::Loop, POE::Loop::Event, POE::Loop::Gtk, POE::Loop::IO_Poll,
POE::Loop::Select, POE::Loop::Tk

POE::Pipe, POE::Pipe::OneWay, POE::Pipe::TwoWay

POE::Preprocessor

POE::Queue, POE::Queue::Array

POE::Resource, POE::Resource::Aliases, POE::Resource::Events,
POE::Resource::Extrefs, POE::Resource::FileHandles,
POE::Resource::Performance, POE::Resource::SIDs,
POE::Resource::Sessions, POE::Resource::Signals

=head1 BUGS

The tests only cover about 70% of POE.

Bug reports, suggestions, and feedback of all kinds should be e-mailed
to <bug-POE@rt.cpan.org>.  It will be entered into our request queue
where it will remain until addressed.  If your return address is
valid, you will be notified when the status of your request changes.

Outstanding issues, including wish list items, are available in POE's
RT queue at L<http://rt.cpan.org/>.

=head1 AUTHORS & COPYRIGHT

POE is the combined effort of several people.  Please let us know if
someone is missing from this list.

TODO: Scour the CHANGES file for credit where it's due.

=over 2

=item Ann Barcomb

Ann Barcomb is <kudra@domaintje.com>, aka C<kudra>.  Ann contributed
large portions of POE::Simple and the code that became the ReadWrite
support in POE::Component::Server::TCP.  Her ideas also inspired
Client::TCP component, introduced in version 0.1702.

=item Artur Bergman

Artur Bergman is <sky@cpan.org>.  He contributed many hours' work into
POE and quite a lot of ideas.  Years later, I decide he's right and
actually implement them.

Artur is the author of Filter::HTTPD and Filter::Reference, as well as
bits and pieces throughout POE.  His feedback, testing, design and
inspiration have been instrumental in making POE what it is today.

Artur is investing his time heavily into perl 5's iThreads and PONIE
at the moment.  This project has far-reaching implications for POE's
future.

=item Jos Boumans

Jos Boumans is <boumans@frg.eur.nl>, aka C<Co-Kane>.  Jos is a major
driving force behind the POE::Simple movement and has helped inspire
the POE::Components for TCP clients and servers.

=item Matt Cashner

Matt Cashner is <sungo@pobox.com>, aka C<sungo>.  Matt is one of POE's
core developers.  He's spearheaded the movement to simplify POE for
new users, flattening the learning curve and making the system more
accessible to everyone.  He uses the system in mission critical
applications, folding feedback and features back into the distribution
for everyone's enjoyment.

=item Andrew Chen

Andrew Chen is <achen-poe@micropixel.com>.  Andrew is the resident
POE/Windows guru.  He contributes much needed testing for Solaris on
the SPARC and Windows on various Intel platforms.

=item Douglas Couch

Douglas Couch is <dscouch@purdue.edu>.  Douglas helped port and
maintain POE for Windows early on.

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
serialization methods.  He has also improved POE's quality by finding
and fixing several bugs.  He provided POE a much needed code review
around version 0.06.

=item Arnar M. Hrafnkelsson

Arnar is <addi@umich.edu>.  Addi tested POE and POE::Component::IRC on
Windows, finding bugs and testing fixes.  He appears throughout the
Changes file.  He has also written "cpoe", which is a POE-like library
for C.

=item Dave Paris

Dave Paris is <dparis@w3works.com>.  Dave tested and benchmarked POE
around version 0.05, discovering some subtle (and not so subtle)
timing problems.  The pre-forking server sample was his idea.
Versions 0.06 and later scaled to higher loads because of his work.
He has contributed a lot of testing and feedback, much of which is
tagged in the Changes file as a-mused.  The man is scarily good at
testing and troubleshooting.

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
multiple files than select().  It's since been moved to
POE::Loop::IO_Poll.

=item Richard Soderberg

Richard Soderberg is <poe@crystalflame.net>, aka C<coral>.  Richard is
a collaborator on several side projects involving POE.  His work
provides valuable testing and feedback from a user's point of view.

=item Dennis Taylor

Dennis Taylor is <dennis@funkplanet.com>.  Dennis has been testing,
debugging and patching bits here and there, such as Filter::Line which
he improved by leaps in 0.1102.  He's also the author of
POE::Component::IRC, the widely popular POE-based successor to his
wildly popular Net::IRC library.

=item Others?

Please contact the author if you've been forgotten.

=back

=head2 Author

=over 2

=item Rocco Caputo

Rocco Caputo is <rcaputo@cpan.org>.  POE is his brainchild.

Except where otherwise noted, POE is Copyright 1998-2005 Rocco Caputo.
All rights reserved.  POE is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=back

Thank you for reading!

=cut
