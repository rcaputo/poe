#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./mylib);
use Test::Harness;
use File::Find;
use File::Spec;

### Some early setup.

# Makefile.PL does this.  Why don't we?
$ENV{PERL_DL_NONLAZY} = 1;

### Run the tests.

my @test_files = gather_test_files();
die "*** Can't find test files" unless @test_files;

runtests(@test_files);
exit;

# Build a list of all the tests to run.

sub gather_test_files {
  my %test_files;

  find(
    sub {
      return unless -f;
      return unless /\.t$/;
      $test_files{File::Spec->catfile($File::Find::dir, $_)} = 1;
    },
    't/',
  );

  return sort keys %test_files;
}
