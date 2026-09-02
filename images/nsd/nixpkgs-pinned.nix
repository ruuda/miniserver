rec {
  owner = "ruuda";
  repo = "nixpkgs";
  commit = "0d0730957ee66aae508c884c63fa96e869631a5c";
  commit_date = "2026-09-02T16:27:47Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-q+tAR+IRwR4vf3eQRnFRwJaKiZipRcxalZEotcVjVE0=";
  };
}
