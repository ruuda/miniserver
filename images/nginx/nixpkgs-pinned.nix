rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "4975466d324710c576dc11ad614684e6bd8cad8e";
  commit_date = "2026-09-23T17:48:10Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=";
  };
}
