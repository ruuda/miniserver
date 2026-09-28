rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "e158d9ed9b51c98974c5e66e1ba1c9e0255fecaa";
  commit_date = "2026-09-26T22:51:50Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-hKlVl12B1dF0Q5vd9dY3lIJM5mFGWYSlXwSLAqHZ1+s=";
  };
}
