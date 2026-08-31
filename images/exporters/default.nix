# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {};
  erofs = (import ./../../build-erofs.nix) { inherit pin; };

  # Smartmontools includes an example Bash script, which brings Bash into
  # the closure. We don't need it, so strip it.
  smartmontools = pkgs.smartmontools.overrideAttrs {
    postInstall = "rm $out/etc/smartd_warning.sh";
  };

  node-exporter = pkgs.prometheus-node-exporter;
  smartctl-exporter = pkgs.prometheus-smartctl-exporter.override {
    smartmontools = smartmontools;
  };
in
  erofs.buildImageManifest rec {
    name = "exporters";
    pkg = node-exporter;
    extraPackages = [ smartctl-exporter ];
    minimize = true;
    extraBuildCommand =
      ''
      # Create a mount point where the systemd unit can mount the host's root
      # file system. It needs to be available for the node_exporter to be able
      # to report properties about filesystem usage.
      mkdir -p $out/host
      ln -s ${node-exporter}/bin/node_exporter $out/usr/bin/node_exporter
      ln -s ${smartctl-exporter}/bin/smartctl_exporter $out/usr/bin/smartctl_exporter
      '';
  }
