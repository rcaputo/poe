#
## Build POD docs from emacs outlines.
## $Id$

all: ../POE.pod ../POE-TODO.pod

../POE.pod: ./POE.outline
	out-out pod  ./POE.outline > ../POE.pod
	out-out html ./POE.outline > ../POE.html

../POE-TODO.pod: ./POE-TODO.outline
	out-out pod  ./POE-TODO.outline > ../POE-TODO.pod
	out-out html ./POE-TODO.outline > ../POE-TODO.html
