rec {
  owner = "nixos";
  repo = "nixpkgs";
  commit = "8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
  commit_date = "2026-09-10T02:20:05Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-xB8mKMOx1IA9vTDNLmJZ6n4wCMq/cuWBBOzGCRnqxrU=";
  };
}
