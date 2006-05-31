#!/usr/bin/env perl

use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::Plugin::Connector
  Component::IRC::Plugin::CTCP);

our $NICK = "poecommits";

our $IN_SERVER = "irc.freenode.net";
our $IN_CHANNEL = "#commits";
our $OUT_SERVER = "irc.perl.org";
our $OUT_CHANNEL = "#poe";

POE::Session->create(
  package_states => [
    'My::Receiver' => [ qw(_start irc_001 irc_public shutdown) ],
  ],
);

POE::Session->create(
  package_states => [
    'My::Transmitter' => [ qw(_start irc_001 irc_public a_commit) ],
  ],
);

{
  package My::Receiver;
  use POE;
  sub _start {
    $_[KERNEL]->alias_set('receiver');
    my $irc = $_[HEAP]->{irc} = POE::Component::IRC->spawn(
      nick => $NICK,
      server => $IN_SERVER,
      ircname => "irc.perl.org #poe commit relay (IN)",
    ) or die $!;
    $irc->yield(register => qw(001 public));
    $irc->plugin_add(Connector => POE::Component::IRC::Plugin::Connector->new);
    $irc->plugin_add(CTCP => POE::Component::IRC::Plugin::CTCP->new);
    $irc->yield(connect => {});
  }
  sub irc_001 {
    $_[KERNEL]->post($_[SENDER] => join => $IN_CHANNEL);
  }
  sub irc_public {
    my ($irc, $who, $where, $what) = ($_[HEAP]->{irc}, @_[ARG0..ARG2]);
    my $channel = $where->[0];
    return unless $channel eq $IN_CHANNEL;
    return unless $who =~ m/^CIA-\d+!.=cia@/i;
    $what =~ s/\cC\d+(,\d+)*//g;
    $what =~ tr/\x00-\x1f//d;
    my ($project) = $what =~ m/(\w{3,}):/;
    print "<$channel> <$who> <$project> <$what>\n";
    return unless $project and $project eq 'poe';
    $_[KERNEL]->post(transmitter => a_commit => $what);
    print "  signaled transmitter\n";
  }
  sub shutdown {
    $_[HEAP]->{irc}->yield('shutdown');
  }
}

{
  package My::Transmitter;
  use POE;
  sub _start {
    $_[KERNEL]->alias_set('transmitter');
    my $irc = $_[HEAP]->{irc} = POE::Component::IRC->spawn(
      nick => $NICK,
      server => $OUT_SERVER,
      ircname => "irc.perl.org #poe commit relay (OUT)",
    ) or die $!;
    $irc->yield(register => qw(001 public));
    $irc->plugin_add(Connector => POE::Component::IRC::Plugin::Connector->new);
    $irc->plugin_add(CTCP => POE::Component::IRC::Plugin::CTCP->new);
    $irc->yield(connect => {});
  }
  sub irc_001 {
    $_[KERNEL]->post($_[SENDER] => join => $OUT_CHANNEL);
  } 
  sub irc_public { }
  sub a_commit {
    print "a_commit <$_[ARG0]>\n";
    $_[HEAP]->{irc}->yield(privmsg => $OUT_CHANNEL => $_[ARG0]);
  }
}

$poe_kernel->run;
