# $Id$

package POE::Macro::UseBytes;
use POE::Preprocessor;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

# Make the "use_bytes" macro evaluate to C<use bytes;> in Perl on or
# after 5.005_55.  Systems before then don't have the option, so the
# macro evaluates to emptiness.  This macro may go away if POE stops
# supporting old Perl versions.

# Macro definitions can't be indented, so this looks ugly.

# The "# include" modifier causes the conditional to be evaluated at
# compile time.  This turns regular if/else logic into the moral
# equivalent of the C preprocessor's #if/#else.

# Because the conditionals are evaluated at compile time, it's
# imperative that the things they test be defined.  The BEGIN block
# makes sure HAS_BYTES is defined before the tests are executed.

BEGIN { eval "use bytes; sub HAS_BYTES () { 1 }";
        eval "sub HAS_BYTES () { 0 }" if $@;
      };

if (HAS_BYTES) { # include
macro use_bytes {
  use bytes;
}
} else { # include
macro use_bytes {
}
} # include

#------------------------------------------------------------------------------
1;
