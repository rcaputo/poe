#!/usr/bin/perl
# $Id$

# This program is Copyright 2002 by Rocco Caputo.  All rights are
# reserved.  This program is free software.  It may be modified, used,
# and redistributed under the same terms as Perl itself.

# Generate a nice looking change log from the CVS logs for a Perl
# project.

use warnings;
use strict;

my $date_range = "-d'1 year ago<'";

my ( %rev, %file, %date, %tag, %tags_by_date, %log, %last_tag_dates, );

sub DUMP_THE_FUN () { 1 }

sub ST_OUTSIDE () { 0x01 }
sub ST_TAGS    () { 0x02 }
sub ST_CHANGE  () { 0x04 }
sub ST_DESC    () { 0x08 }
sub ST_SKIP    () { 0x10 }

sub FL_DATE () { 0 }
sub FL_AUTH () { 1 }
sub FL_DESC () { 2 }

sub LOG_VER  () { 0 }
sub LOG_DSC  () { 1 }
sub LOG_AUTH () { 2 }

### Gather the change log information for the date range.

my $log_state = ST_OUTSIDE;
my $log_file  = "";
my $log_ver   = "";
my $rcs_file  = "";

open("LOG", "/usr/bin/cvs log $date_range .|") or die "can't get cvs log: $!";

while (<LOG>) {
  chomp;
  process_outside(),next if $log_state & ST_OUTSIDE;
  process_tags(),next    if $log_state & ST_TAGS;
  process_change(),next  if $log_state & ST_CHANGE;
  process_desc(),next    if $log_state & ST_DESC;
  process_skip(),next    if $log_state & ST_SKIP;
}

close LOG;

sub process_outside {
  if (/^Working file:\s+(.+?)\s*$/) {
    $log_file = $1;
    die if exists $file{$log_file};
    return;
  }

  if (/^RCS file:.*?\/Attic\//) {
    $log_state = ST_SKIP;
    return;
  }

  if (/^symbolic names:/) {
    $log_state = ST_TAGS;
    return;
  }

  if (/^revision\s+([\d\.]+)/) {
    $log_ver = $1;
    $log_state = ST_CHANGE;
    return;
  }
}

sub process_tags {
  if (my ($tag, $ver) = /^\s+(.+):\s+(\S+)$/) {
    $rev{$tag}{$log_file} = $ver;
    $tag{$log_file}{$ver} = $tag;
    return;
  }
  if (/^\S/) {
    $log_state = ST_OUTSIDE;
    return;
  }
}

sub process_change {
  my @fields = split /\s*\;\s+/;
  my %field;
  foreach my $field (@fields) {
    my ($f, $v) = split /\s*\:\s+/, $field, 2;
    $field{$f} = $v;
  }

  die unless exists $field{date};
  $field{date} =~ /(\d+)\/(\d+)\/(\d+)\s+(\d+:\d+:\d+)/;

  my $timestamp = "$1-$2-$3 $4";
  $file{$log_file}{$log_ver} =
    [ $timestamp,      # FL_DATE
      $field{author},  # FL_AUTH
      "",              # FL_DESC
    ];

  $date{$timestamp}{$log_file} = $log_ver;

  $log_state = ST_DESC;
}

sub process_desc {
  if ($_ eq ("-" x 28) or $_ eq ("=" x 77)) {
    $log_state = ST_OUTSIDE;
    return;
  }
  $file{$log_file}{$log_ver}[FL_DESC] .= "$_\n";
}

sub process_skip {
  $log_state = ST_OUTSIDE if $_ eq ("=" x 77);
}

### Helper to compare CVS revisions.

sub rev_compare {
  my ($a, $b) = @_;

  my @a = split /\./, $a;
  my @b = split /\./, $b;

  while (@a and @b) {
    my $sub_a = shift @a;
    my $sub_b = shift @b;
    return $sub_a <=> $sub_b if $sub_a <=> $sub_b;
  }

  return  1 if @a;
  return -1 if @b;
  return  0;
}

### Group entries by tag, date, and file.

sub find_tag {
  my ($file, $version) = @_;

  my $tags = $tag{$file};
  my @versions = sort { rev_compare($a,$b) } keys %$tags;
  foreach my $scan_version (@versions) {
    next if rev_compare($version, $scan_version) > 0;
    return $tag{$file}{$scan_version};
  }

  return "untagged";
}

foreach my $file (keys %file) {
  while (my ($version, $file_rec) = each(%{$file{$file}})) {
    my $date = $file_rec->[FL_DATE];
    my $tag = find_tag($file, $version);

    if (exists $last_tag_dates{$tag}) {
      $last_tag_dates{$tag} = $date if $last_tag_dates{$tag} lt $date;
    }
    else {
      $last_tag_dates{$tag} = $date;
    }

    # Skip files which are not tagged and do not exist.
    next if $tag eq "untagged" and not -e $file;

    $log{$tag}{$date}{$file_rec->[FL_AUTH]}{$file_rec->[FL_DESC]}{$file} =
      $version;
  }
}

### Generate the log file.

#while (my ($tag, $date) = each %last_tag_dates) {
#  print "$tag = $date\n";
#}

while (my ($tag, $date) = each %last_tag_dates) {
  if (exists $tags_by_date{$date}) {
    die( "There are two tags for the same date/time stamp.\n",
         "That is not yet supported.\n",
         "The date/time stamp: $date\n",
         "The tags are ``$tag'' and ``$tags_by_date{$date}''.\n",
         "You may need to use ``cvs tag -d <tag>'' to delete one of them.\n",
         "Be careful!  There is no undo for this.\n",
       );
  }

  $tags_by_date{$date} = $tag;
}

foreach my $tag_date (sort { $b cmp $a } keys %tags_by_date) {
  my $tag = $tags_by_date{$tag_date};

  my $tag_line = "$tag_date $tag";

  print( ("=" x length($tag_line)), "\n",
         $tag_line, "\n",
         ("=" x length($tag_line)), "\n\n",
       );

  # Using \x00 tricks here so that files and versions wrap together.

  foreach my $date (sort keys %{$log{$tag}}) {
    foreach my $auth (sort keys %{$log{$tag}{$date}}) {
      foreach my $desc (sort keys %{$log{$tag}{$date}{$auth}}) {
        my @files;
        while (my ($file, $ver) = each %{$log{$tag}{$date}{$auth}{$desc}}) {
          push @files, "$file\x00$ver";
        }

        use Text::Wrap qw(wrap fill $columns $huge);
        $Text::Wrap::huge = "wrap";
        $Text::Wrap::columns = 74;

        my $date_line = wrap("  ", "  ", join("; ", "$date; $auth", @files));
        if ($date_line =~ /\n/) {
          my $new_date_line = ( wrap("  ", "  ", "$date; $auth\n") .
                                wrap("  ", "  ", join("; ", @files))
                              );
          $date_line = $new_date_line if $new_date_line !~ /\n.*?\n/;
        }
        $date_line =~ tr[\x00][ ];

        print( $date_line, "\n\n",
               fill("\t", "\t", $desc), "\n\n",
             );
      }
    }
  }
}

### Dump what we have so far.

#use YAML qw(freeze);
#print "===== log =====\n";
#print freeze \%log;
#print "===== rev =====\n";
#print freeze \%rev;
#print "===== file =====\n";
#print freeze \%file;
#print "===== date =====\n";
#print freeze \%date;
#print "===== tag =====\n";
#print freeze \%tag;
#print "===== tags by date =====\n";
#print freeze \%tags_by_date;
#print "===== last tag dates =====\n";
#print freeze \%last_tag_dates;

print( "=============================\n",
       "Beginning of Recorded History\n",
       "=============================\n"
     );
