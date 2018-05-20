// Miniserver -- Nginx and Acme-client on CoreOS.
// Copyright 2018 Ruud van Asseldonk

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License version 3. A copy
// of the License is available in the root of the repository.

#include <signal.h>
#include <stdio.h>

int main(int argc, char** argv) {
  printf(
    "Miniserver does not provide a login prompt. It has no shell anyway.\n"
    "If you need to execute a command, do so via ssh.\n"
  );

  // Run indefinitely without consuming system resources.
  // A SIGTERM ends the program, sigsuspend does not return in that case.
  sigset_t sigmask;
  sigemptyset(&sigmask);
  while (1) sigsuspend(&sigmask);
}
