#!/usr/bin/perl
# $Id$

# This program is Copyright 2002 by Rocco Caputo.  All rights are
# reserved.  This program is free software.  It may be modified, used,
# and redistributed under the same terms as Perl itself.

# Generate a nice looking change log from the CVS logs for a Perl
# project.

use strict;

use Text::Wrap qw(wrap fill $columns $huge);
$Text::Wrap::huge = "wrap";
$Text::Wrap::columns = 74;

use Time::Local;

my $date_range = "-d'1 year ago<'";
# $date_range = "-d'2 years ago<'";

my ( %rev, %file, %time, %tag, %tags_by_time, %log, %last_tag_times, );

sub DUMP_THE_FUN () { 1 }

sub ST_OUTSIDE () { 0x01 }
sub ST_TAGS    () { 0x02 }
sub ST_CHANGE  () { 0x04 }
sub ST_DESC    () { 0x08 }
sub ST_SKIP    () { 0x10 }

sub FL_TIME () { 0 }
sub FL_AUTH () { 1 }
sub FL_DESC () { 2 }

sub LOG_VER  () { 0 }
sub LOG_DSC  () { 1 }
sub LOG_AUTH () { 2 }

### Gather the change log information for the date range, and collate
### it a number of ways.

my $log_state = ST_OUTSIDE;
my $log_file  = "";
my $log_ver   = "";
my $rcs_file  = "";

open(LOG, "/usr/bin/cvs log $date_range .|") or die "can't get cvs log: $!";

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
  $field{date} =~ /(\d+)\/(\d+)\/(\d+)\s+(\d+):(\d+):(\d+)/;
  my $time = timegm($6, $5, $4, $3, $2-1, $1-1900);

  $file{$log_file}{$log_ver} =
    [ $time,           # FL_TIME
      $field{author},  # FL_AUTH
      "",              # FL_DESC
    ];

  $time{$time}{$log_file} = $log_ver;

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

### Normalize descriptions.

foreach my $file (keys %file) {
  foreach my $ver (keys %{$file{$file}}) {
    my $desc = fill("    ", "    ", $file{$file}{$ver}[FL_DESC]);
    $file{$file}{$ver}[FL_DESC] = $desc;
  }
}

### Group entries by tag, time, and file.

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

### Find the last commit under each tag, and use that commit's
### timestamp as the tag's.

foreach my $file (keys %file) {
  while (my ($version, $file_rec) = each(%{$file{$file}})) {
    my $time = $file_rec->[FL_TIME];
    my $tag = find_tag($file, $version);

    if (exists $last_tag_times{$tag}) {
      $last_tag_times{$tag} = $time if $last_tag_times{$tag} lt $time;
    }
    else {
      $last_tag_times{$tag} = $time;
    }

    # Skip files which are not tagged and do not exist.
    next if $tag eq "untagged" and not -e $file;

    $log{$tag}{$time}{$file_rec->[FL_AUTH]}{$file_rec->[FL_DESC]}{$file} =
      $version;
  }
}

### Generate the log file.

while (my ($tag, $time) = each %last_tag_times) {
  if (exists $tags_by_time{$time}) {
    warn( "There are two tags for the same time stamp.\n",
          "That is not yet supported.\n",
          "The time stamp: $time\n",
          "The tags are ``$tag'' and ``$tags_by_time{$time}''.\n",
          "You may need to use ``cvs tag -d <tag>'' to delete one of them.\n",
          "Be careful!  There is no undo for this.\n",
        );

    if (lc($tag) eq "start") {
      warn( "Ignoring tag ``$tags_by_time{$time}'' ",
            "which coincides with ``$tag''\n"
          );
      delete $tags_by_time{$time};
    }
    elsif (lc($tags_by_time{$time}) eq "start") {
      warn( "Ignoring tag ``$tag'' ",
            "which coincides with ``$tags_by_time{$time}''\n"
          );
      next;
    }
  }

  $tags_by_time{$time} = $tag;
}

### Return human readable time from UNIX's epoch.

sub format_time {
  my $time = shift;
  my ($sc, $mn, $hr, $dd, $mm, $yy) = gmtime($time);
  sprintf("%04d-%02d-%02d %02d:%02d:%02d",
          $yy+1900, $mm+1, $dd, $hr, $mn, $sc,
         );
}

### Finally collate everything into a report.

foreach my $tag_time (sort { $b <=> $a } keys %tags_by_time) {
  my $tag = $tags_by_time{$tag_time};

  my $tag_line = format_time($tag_time) . " " . $tag;

  print( ("=" x length($tag_line)), "\n",
         $tag_line, "\n",
         ("=" x length($tag_line)), "\n\n",
       );

  # Combine adjacent identical log descriptions.  DEEP HURTING!  This
  # migrates older commits (earlier in time) to more recent/later
  # times if the commits are adjacent in the log and have identical
  # commit notes.  Should this be a separate step outside the report?

  my @times = sort { $a <=> $b } keys %{$log{$tag}};
  my $time_index = 1;

TIME:
  while ($time_index < @times) {
    my $then = $times[$time_index-1]; # Older commit time.
    my $now  = $times[$time_index];   # Newer commit time.

    foreach my $auth (sort keys %{$log{$tag}{$then}}) {
      next TIME unless exists $log{$tag}{$now}{$auth};
      foreach my $desc (sort keys %{$log{$tag}{$then}{$auth}}) {
        next TIME unless exists $log{$tag}{$now}{$auth}{$desc};
        foreach my $file (keys %{$log{$tag}{$then}{$auth}{$desc}}) {

          if (exists $log{$tag}{$now}{$auth}{$desc}{$file}) {
            delete $log{$tag}{$then}{$auth}{$desc}{$file};
          }
          else {
            $log{$tag}{$now}{$auth}{$desc}{$file} =
              delete $log{$tag}{$then}{$auth}{$desc}{$file};
          }
        }
        delete $log{$tag}{$then}{$auth}{$desc}
          unless keys %{$log{$tag}{$then}{$auth}{$desc}};
      }
      delete $log{$tag}{$then}{$auth}
        unless keys %{$log{$tag}{$then}{$auth}};
    }
    delete $log{$tag}{$then}
      unless keys %{$log{$tag}{$then}};
  }
  continue {
    $time_index++;
  }

  # Report the commits underneath the current tag.

  foreach my $time (sort { $b <=> $a } keys %{$log{$tag}}) {
    foreach my $auth (sort keys %{$log{$tag}{$time}}) {
      foreach my $desc (sort keys %{$log{$tag}{$time}{$auth}}) {

        # Build a sorted list of files and their versions.  The "\x00"
        # acts as a non-breaking space here.  We use tr[][] later to
        # convert it back.

        my @files = sort keys %{$log{$tag}{$time}{$auth}{$desc}};
        foreach my $file (@files) {
          $file .= "\x00" . $log{$tag}{$time}{$auth}{$desc}{$file};
        }

        my $human_time = format_time($time);
        my $time_line = wrap( "  ", "  ",
                              join("; ", "$human_time by $auth", @files)
                            );
        if ($time_line =~ /\n/) {
          my $new_time_line = ( wrap("  ", "  ",
                                     "$human_time by $auth\n"
                                    ) .
                                wrap("  ", "  ", join("; ", @files))
                              );
          $time_line = $new_time_line if $new_time_line !~ /\n.*?\n/;
        }
        $time_line =~ tr[\x00][ ];

        print $time_line, "\n\n", $desc, "\n\n";
      }
    }
  }
}

print( "=============================\n",
       "Beginning of Recorded History\n",
       "=============================\n"
     );

### Dump what we have so far.

#use YAML qw(freeze);
#print "===== log =====\n";
#print freeze \%log;
#print "===== rev =====\n";
#print freeze \%rev;
#print "===== file =====\n";
#print freeze \%file;
#print "===== time =====\n";
#print freeze \%time;
#print "===== tag =====\n";
#print freeze \%tag;
#print "===== tags by time =====\n";
#print freeze \%tags_by_time;
#print "===== last tag times =====\n";
#print freeze \%last_tag_times;
