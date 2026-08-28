rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "9fbb54b33e91ee4ca368e35a78e0613c720600b3";
  commit_date = "2026-08-26T09:33:39Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-cV5xEJJK3BvhU8rEd4mC9UsmDi5qscv/kzGPhBRC5WA=";
  };
}
