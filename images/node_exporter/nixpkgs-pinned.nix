rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "567a49d1913ce81ac6e9582e3553dd90a955875f";
  commit_date = "2026-06-16T02:33:49Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-lrp67w8AulE9Ks53n27I45ADSzbOCn4H+CNW1Ck8B+8=";
  };
}
