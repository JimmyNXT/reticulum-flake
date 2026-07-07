{ reticulumPackage }:

{ config, pkgs, lib, ... }:

{
  users.groups.nomadnet = { };

  users.users.nomadnet = {
    isSystemUser = true;
    group = "nomadnet";
    home = "/var/lib/nomadnet";
    createHome = true;
    shell = pkgs.bashInteractive;
  };

  environment.systemPackages = [ pkgs.tmux reticulumPackage ];

  # rnsd owns the actual Reticulum interfaces / shared instance. Type=simple
  # means systemd considers it "started" the instant the process forks, not
  # when its Transport is actually ready - see nomadnet.service below.
  systemd.services.rnsd = {
    description = "Reticulum Network Stack Daemon";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "nomadnet";
      ExecStart = "${reticulumPackage}/bin/rnsd";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # nomadnet is a full-screen TUI, so it runs detached inside tmux (default
  # socket, not a custom -L one - `tmux attach -t nomadnet` should just work).
  #
  # Restart=always (not on-failure) plus the widened start-limit is the fix
  # for a non-deterministic race found by testing real reboots on vm158:
  # nomadnet occasionally exits cleanly (status=0) shortly after launch, even
  # after rnsd's shared-instance socket is confirmed listening - timing tests
  # showed this isn't a fixed-duration race, it's an intermittent hiccup in
  # the RNS shared-instance handshake itself. Because the exit is clean,
  # Restart=on-failure would never retry it; Restart=always does, and it
  # reliably succeeds a few seconds later.
  systemd.services.nomadnet = {
    description = "Nomadnet";
    after = [ "network.target" "rnsd.service" ];
    requires = [ "rnsd.service" ];
    wantedBy = [ "multi-user.target" ];
    startLimitIntervalSec = 300;
    startLimitBurst = 10;
    serviceConfig = {
      Type = "forking";
      User = "nomadnet";
      ExecStartPre = pkgs.writeShellScript "nomadnet-wait-for-rnsd" ''
        for i in $(seq 1 30); do
          ${pkgs.iproute2}/bin/ss -xl 2>/dev/null | grep -q "@rns/default" && exit 0
          sleep 0.5
        done
      '';
      ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s nomadnet '${reticulumPackage}/bin/nomadnet'";
      ExecStop = "-${pkgs.tmux}/bin/tmux kill-session -t nomadnet";
      Restart = "always";
      RestartSec = 5;
    };
  };
}
