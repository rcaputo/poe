# $Id$

package POE::Preprocessor;

use strict;
use Filter::Util::Call;

sub MAC_PARAMETERS () { 0 }
sub MAC_CODE       () { 1 }

sub DEBUG     () { 0 }
sub DEBUG_ROP () { 0 } # Regexp optimizer.

# Create an optimal regexp to match a list of things.
my $debug_level = 0;

sub optimum_match {
  my @sorted = sort { (length($b) <=> length($a)) || ($a cmp $b) } @_;
  my @regexp;
  my $width = 40 - $debug_level;

  DEBUG_ROP and do {
    warn ' ' x $debug_level, "+-----\n";
    warn ' ' x $debug_level, "| Given: @sorted\n";
    warn ' ' x $debug_level, "+-----\n";
  };

  while (@sorted) {
    my $longest = $sorted[0];

    DEBUG_ROP and do {
      warn ' ' x $debug_level, "+-----\n";
      warn( ' ' x $debug_level,
            "| Longest : ",
            sprintf("%-${width}s", unpack('H*', $longest)),
            " ($longest)\n"
          );
    };

    # Find the length of the longest match.
    my $minimum_match_count = length $longest;
    foreach (@sorted) {
      my $xor = $_ ^ $longest;
      if (($xor =~ /^(\000+)/) and (length($1) < $minimum_match_count)) {
        $minimum_match_count = length($1);
      }
    }

    DEBUG_ROP and
      warn ' ' x $debug_level, "| sz_match: $minimum_match_count\n";

    # Extract the things matching it.
    my $minimum_match_string = substr($longest, 0, $minimum_match_count);
    DEBUG_ROP and
      warn ' ' x $debug_level, "| st_match: $minimum_match_string\n";

    my @matches = grep /^$minimum_match_string/, @sorted;
    @sorted = grep !/^$minimum_match_string/, @sorted;

    # Only one match? Nothing to compare, or anything.
    if (@matches == 1) {
      DEBUG_ROP and warn ' ' x $debug_level, "| matches : $matches[0]\n";
      push @regexp, $matches[0];
    }

    # More than one match? Recurse!
    else {
      # Remove the common prefix.
      my $matches_index = @matches;
      while ($matches_index--) {
        $matches[$matches_index] =~ s/^$minimum_match_string//;
        splice(@matches, $matches_index, 1)
          unless length $matches[$matches_index];
      }

      # If only one left now, then it's an optional prefix.
      if (@matches == 1) {
        my $sub_expression = "$minimum_match_string(?:$matches[0])?";
        DEBUG_ROP and warn ' ' x $debug_level, "| option  : $sub_expression\n";
        push @regexp, $sub_expression;
      }
      else {
        DEBUG_ROP and warn ' ' x $debug_level, "| recurse : @matches\n";

        $debug_level++;
        my $sub_expression = &optimum_match(@matches);
        $debug_level--;

        # Build part of this regexp.
        push @regexp, '(?:' . $minimum_match_string . $sub_expression . ')';
      }
    }
  }

  my $sub_expression = '(?:' . join('|', @regexp). ')';

  DEBUG_ROP and do {
    warn ' ' x $debug_level, "+-----\n";
    warn ' ' x $debug_level, "| Returns: $sub_expression\n";
    warn ' ' x $debug_level, "+-----\n";
  };

  $sub_expression;
}


sub import {

  # Outer closure to define a unique scope.
  { my $macro_name = '';
    my ($macro_line, %macros, %constants, $const_regexp, $enum_index);
    my ($file_name, $line_number) = (caller)[1,2];
    my $const_regexp_dirty = 0;

    my $set_const = sub {
      my ($name, $value) = @_;

      if (exists $constants{$name}) {
        warn "const $name redefined at $file_name line $line_number\n";
      }

      $constants{$name} = $value;
      $const_regexp_dirty++;

      DEBUG and
        warn( ",-----\n",
              "| Defined a constant: $name = $value\n",
              "`-----\n"
            );
    };

    # Define the filter sub.
    filter_add
      ( sub {
          my $status = filter_read();
          $line_number++;

          # Handle errors or EOF.
          return $status if $status <= 0;

          # Inside a macro definition.
          if ($macro_name ne '') {

            DEBUG and warn sprintf "%4d M: %s", $line_number, $_;

            # Close it!
            if (/^\}$/) {

              DEBUG and
                warn( ",-----\n",
                      "| Defined macro $macro_name\n",
                      "| Parameters: ",
                      @{$macros{$macro_name}->[MAC_PARAMETERS]}, "\n",
                      "| Code: {\n",
                      $macros{$macro_name}->[MAC_CODE],
                      "| }\n",
                      "`-----\n"
                    );

              unless ($macros{$macro_name}->[MAC_CODE] =~ /\;$/) {
                $macros{$macro_name}->[MAC_CODE] =~ s/^\s*//;
                $macros{$macro_name}->[MAC_CODE] =~ s/\s*$//;
              }

              $macro_name = '';
            }

            # Otherwise append this line to the macro.
            else {
              $macro_line++;

              # Unindent the macro text by one level.  -><- This
              # assumes the author's indenting style, two spaces,
              # which is bad.
              s/^\s\s//;

              $macros{$macro_name}->[MAC_CODE] .=
                "# line $macro_line \"macro $macro_name\"\n$_";
            }

            # Either way, the code must not go on.
            $_ = "\n";
            return $status;
          }

          # The next two returns speed up multiple const/enum
          # definitions in the same area.  They also eliminate the
          # need to check for things in semantically nil lines.

          # Ignore comments.
          return $status if /^\s*\#/;

          # Ignore blank lines.
          return $status if /^\s*$/;

          # This return works around a bug where __END__ and __DATA__
          # cause perl 5.005_61 through 5.6.0 to blow up with memory
          # errors.  It detects these tags, replaces them with a blank
          # line, and simulates EOF.
          if (/^__(END|DATA)__\s*$/) {
            $_ = "\n";
            return 0;
          }

          # Define an enum.
          if (/^enum(?:\s+(\d+|\+))?\s+(.*?)\s*$/) {
            $enum_index = ( (defined $1)
                            ? ( ($1 eq '+')
                                ? $enum_index
                                : $1
                              )
                            : 0
                          );
            foreach (split /\s+/, $2) {
              &{$set_const}($_, $enum_index++);
            }
            $_ = "\n";
            return $status;
          }

          # Define a constant.
          if (/^const\s+([A-Z_][A-Z_0-9]+)\s+(.+?)\s*$/) {
            &{$set_const}($1, $2);
            $_ = "\n";
            return $status;
          }

          # Define a macro.
          if (/^macro\s*(\w+)\s*(?:\((.*?)\))?\s*\{\s*$/) {

            DEBUG and warn sprintf "%4d D: %s", $line_number, $_;

            $macro_name = $1;
            $macro_line = 0;
            my @macro_params =
              ( (defined $2)
                ? split(/\s*\,\s*/, $2)
                : ()
              );

            if (exists $macros{$macro_name}) {
              warn( "macro $macro_name redefined ",
                    "at $file_name line $line_number\n"
                  );
            }

            $macros{$macro_name} = [ ];
            $macros{$macro_name}->[MAC_PARAMETERS] = \@macro_params;
            $macros{$macro_name}->[MAC_CODE] = '';

            $_ = "\n";

            return $status;
          }

          # Perform macro substitutions.
          while (/^(.*?)\{\%\s+(\S+)\s*(.*?)\s*\%\}(.*)$/s) {

            DEBUG and warn sprintf "%4d S: %s", $line_number, $_;

            my ($left, $name, $params, $right) = ($1, $2, $3, $4);
            DEBUG and
              warn ",-----\n| macro invocation: $name $params\n";

            if (exists $macros{$name}) {
              my @use_params = split /\s*\,\s*/, $params;
              my @mac_params = @{$macros{$name}->[MAC_PARAMETERS]};

              if (@use_params != @mac_params) {
                warn( "macro $name paramter count (",
                      scalar(@use_params),
                      ") doesn't match defined count (",
                      scalar(@mac_params),
                      ") at $file_name line $line_number\n"
                    );
                return $status;
              }

              # Build a new bit of code here.
              my $substitution = "\n" . $macros{$name}->[MAC_CODE];

              foreach my $mac_param (@mac_params) {
                my $use_param = shift @use_params;
                1 while ($substitution =~ s/$mac_param/$use_param/g);
              }

              $_ = $left . $substitution . $right .
                "# line " . ($line_number+1) . " \"$file_name\"\n";

              DEBUG and warn "$_`-----\n";
            }
            else {
              warn( "macro $name has not been defined ",
                    "at $file_name line $line_number\n"
                  );
              last;
            }
          }

          # Only rebuild the constant regexp if necessary.  This
          # prevents redundant regexp rebuilds when defining several
          # constants all together.
          if ($const_regexp_dirty) {
            $const_regexp = &optimum_match(keys %constants);
            $const_regexp_dirty = 0;
          }

          # Perform constant substitutions.
          if (defined $const_regexp) {
            s/\b($const_regexp)\b/$constants{$1}/sg;
          }

          # Unmolested lines.
          DEBUG and warn sprintf "%4d |: %s", $line_number, $_;

          $status;
        }
      );
  }
}

1;

__END__

=head1 NAME

POE::Preprocessor - A Macro Preprocessor

=head1 SYNOPSIS

  use POE::Preprocessor;

  macro max (one,two) {
    ((one) > (two) ? (one) : (two))
  }

  print {% max $one, $two %}, "\n";

  const PI 3.14159265359

  print "PI\n";  # Substitutions don't grok Perl!

  enum ONE TWO THREE
  enum 12 TWELVE THIRTEEN FOURTEEN
  enum + FIFTEEN SIXTEEN SEVENTEEN

  print "ONE TWO THREE TWELVE THIRTEEN FOURTEEN FIFTEEN SIXTEEN SEVENTEEN\n";

=head1 DESCRIPTION

POE::Preprocessor is a Perl source filter that implements a simple
macro substitution language.

The preprocessor defines a "macro" command:

  macro macro_name (parameter list) {
    macro code
  }

The parameter list is optional for macros that don't accept
parameters.

Macros are substituted into a program with a syntax borrowed from
Iaijutsu and altered slightly to jive with Perl's native syntax.

  {% macro_name parameter,list %}

Constants are defined this way:

  const CONSTANT_NAME 'constant value'

Enumerations can begin with 0:

  enum ZEROTH FIRST SECOND ...

Or some other number:

  enum 10 TENTH ELEVENTH TWELVTH

Or continue where the previous one left off, which is necessary
because an enumeration can't span lines:

  enum +  THIRTEENTH FOURTEENTH FIFTEENTH ...

=head1 BUGS

=over 2

=item *

Macro invocations may not span lines, but macro definitions may.

=item *

The regular expressions that detect and replace code are simplistic
and may not do the right things when given challenging Perl syntax to
parse.  This includes placing constants in strings.

=item *

Substitution is done in two phases: macros first, then constants.  It
would be nicer (and more dangerous) if the phases looped around and
around until no more substitutions occurred.

=back

=head1 AUTHOR & COPYRIGHT

POE::Preprocessor is Copyright 2000 Rocco Caputo.  All rights
reserved.  POE::Preprocessor is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut
