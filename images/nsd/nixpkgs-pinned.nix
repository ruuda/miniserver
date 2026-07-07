rec {
  owner = "ruuda";
  repo = "nixpkgs";
  commit = "4084e54525168f4e4674a1d3b6a03ba120830815";
  commit_date = "2026-07-07T12:18:15Z";
  tarball = fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${commit}.tar.gz";
    sha256 = "sha256-4VaerKphMWEnSmSR0/bqykj5Y62xfsSIRiAENFh7VJY=";
  };
}
