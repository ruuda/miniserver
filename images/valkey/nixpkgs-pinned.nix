rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "b5aa0fbd538984f6e3d201be0005b4463d8b09f8";
  commit_date = "2026-06-29T09:01:53Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-oPXCU/SSUokcGaJREHibG1CBX3+s/W7orDWQOZDsEeQ=";
  };
}
