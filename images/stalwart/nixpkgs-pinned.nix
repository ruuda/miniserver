rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "e8be7818e19ada32105a8af937a6a473b38167ca";
  commit_date = "2026-08-29T00:50:12Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-0N9nghg3nwzX6b6qc77EzjR9cu/Z+UR66FlfsCqiURs=";
  };
}
