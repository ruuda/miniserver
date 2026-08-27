rec {
  owner = "ruuda";
  repo = "nixpkgs";
  commit = "e7abad2faa3e5bfd7f66889949196add1236362a";
  commit_date = "2026-08-27T11:33:16Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-BZUZy0WWDQHfihO3bp5XS3e/6E65PUyYvXrGA/Eadkc=";
  };
}
