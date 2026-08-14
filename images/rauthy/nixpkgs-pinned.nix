rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "0e251e24a4f24e036a084b6b4b2d2491af4167f4";
  commit_date = "2026-08-13T05:33:33Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-yNJd40f11EzXBjSByCB7IPpeFFAdeoSKKM67dGkfFoU=";
  };
}
