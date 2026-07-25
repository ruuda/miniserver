rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "e2587caef70cea85dd97d7daab492899902dbf5d";
  commit_date = "2026-07-23T08:54:16Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-wWFrV5/Qbm+lyt5x20E/bSbfJiGKMo4RCxZV8cl/WZI=";
  };
}
