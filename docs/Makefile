#
## Build POD docs from emacs outlines.
## $Id$

all: ../POE.pod ../POE-TODO.pod

../POE.pod: ./POE.outline
	./out-out.perl pod  ./POE.outline > ../POE.pod
	./out-out.perl html ./POE.outline > ../POE.html

../POE-TODO.pod: ./POE-TODO.outline
	./out-out.perl pod  ./POE-TODO.outline > ../POE-TODO.pod
	./out-out.perl html ./POE-TODO.outline > ../POE-TODO.html
