rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "34ab99075ac4f7e40cf037eef32cb1c360bb85e9";
  commit_date = "2026-08-31T12:23:27Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-hn1oU2rue2SYK8dAr8+WNZWtbsz1S2W5mnHlSEuh3bo=";
  };
}
