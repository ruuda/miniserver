rec {
  owner = "ruuda";
  repo = "nixpkgs";
  commit = "904dd9839a463bf89bc6c97a269da3a05326b74d";
  commit_date = "2026-06-25T20:06:58Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-FuBrxQt8QIIk7RTlsfju5oKLTOp+LvHJYrzTuDU3kFA=";
  };
}
