rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "b1b875982b17dabde9b4a37f3e229e74913e6db3";
  commit_date = "2026-09-16T08:07:56Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-zVxLZiSnmaaPLwnhj7pwmqe3axBg/C6nG5JZsJMh2g4=";
  };
}
