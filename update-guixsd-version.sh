#!/bin/sh

curl --silent 'https://git.savannah.gnu.org/cgit/guix.git/atom/?h=master' \
  | sed "1 s/xmlns='.*'//g" \
  | xmllint --xpath '/feed/entry[1]/id/text()' - \
  > guixsd-version.lock

# Also add a newline.
echo "" >> guixsd-version.lock
