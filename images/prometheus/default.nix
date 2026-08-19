# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {};
  erofs = (import ./../../build-erofs.nix) { inherit pin; };

  prometheus = pkgs.prometheus.override {
    # Disable stuff we don't use to reduce attack surface.
    enableAWS = false;
    enableAzure = false;
    enableConsul = false;
    enableDigitalOcean = false;
    enableEureka = false;
    enableGCE = false;
    enableHetzner = false;
    enableIONOS = false;
    enableKubernetes = false;
    enableLinode = false;
    enableMarathon = false;
    enableMoby = false;
    enableNomad = false;
    enableOVHCloud = false;
    enableOpenstack = false;
    enablePuppetDB = false;
    enableSTACKIT = false;
    enableScaleway = false;
    enableTriton = false;
    enableUyuni = false;
    enableVultr = false;
    enableXDS = false;
    enableZookeeper = false;

    # THis is enabled by default, but let's be explicit about it.
    enableDNS = true;
  };

  alertmanager = pkgs.prometheus-alertmanager;
in
  erofs.buildImageManifest rec {
    name = "prometheus";
    pkg = prometheus;
    extraPackages = [ alertmanager ];
    minimize = true;
    extraBuildCommand =
      ''
      # Make both a directory and a file, so we can bind-mount either into the
      # deployment.
      mkdir -p $out/etc/prometheus $out/etc/alertmanager
      touch $out/etc/prometheus/prometheus.yml
      touch $out/etc/alertmanager/alertmanager.yml
      mkdir -p $out/var/lib/prometheus
      ln -s ${prometheus}/bin/prometheus $out/usr/bin/prometheus
      ln -s ${alertmanager}/bin/alertmanager $out/usr/bin/alertmanager
      '';
  }
