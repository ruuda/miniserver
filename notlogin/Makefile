notlogin: notlogin.c
	# Pass -Os to optimize for size.
	cc -o notlogin -Wall -Werror -Os notlogin.c

install: notlogin
	mkdir -p ${out}/bin
	cp notlogin ${out}/bin
