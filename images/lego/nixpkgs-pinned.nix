rec {
  owner = "ruuda";
  repo = "nixpkgs";
  commit = "69d860e0e0e115deecf32e235e279cca0bb67545";
  commit_date = "2026-05-15T09:23:15Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-Ge9fB7iLOThZaiUEG6GoUPjF3JB7OFY/7BLv8WG4hTo=";
  };
}
