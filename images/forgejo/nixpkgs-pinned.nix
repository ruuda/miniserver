rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "753cc8a3a87467296ddd1fa93f0cc3e81120ee46";
  commit_date = "2026-07-15T13:07:34Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-KesHgItiZPgGX740axSiQLcIQ8D24MDqNpkKYWIek8k=";
  };
}
