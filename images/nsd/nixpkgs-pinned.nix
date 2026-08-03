rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "148bab9c1c3c53136ecb44a6ea356a0ed5b39b06";
  commit_date = "2026-08-01T07:59:56Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-KoTsyMQqnXQZq8deCEnu4QkyldkwH/bpMMhUcfMdGIw=";
  };
}
