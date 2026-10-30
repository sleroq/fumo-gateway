{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fumo-gateway;
  format = pkgs.formats.json { };
in
{
  options.services.fumo-gateway = {
    enable = lib.mkEnableOption "Fumo gateway";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "inputs.fumo-gateway.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "Fumo gateway package, using the flake's own nixpkgs pin by default.";
    };

    settings = lib.mkOption {
      type = lib.types.submodule ./settings.nix;
      default = { };
      description = ''
        Gateway JSON configuration. Use key_env for secrets and put their values
        in environmentFile, not in the world-readable Nix store. Writable OAuth
        credentials should live under /var/lib/fumo-gateway.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/fumo-gateway.env";
      description = "Runtime systemd environment file containing client, admin, and upstream keys.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = format.generate "fumo-gateway.json" cfg.settings;
      description = "Generated configuration, also available to external service managers.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    users.groups.fumo-gateway = { };
    users.users.fumo-gateway = {
      isSystemUser = true;
      group = "fumo-gateway";
      home = "/var/lib/fumo-gateway";
    };

    systemd.services.fumo-gateway = {
      description = "Fumo gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} --config ${cfg.configFile}";
        User = "fumo-gateway";
        Group = "fumo-gateway";
        WorkingDirectory = "/var/lib/fumo-gateway";
        StateDirectory = "fumo-gateway";
        StateDirectoryMode = "0700";
        UMask = "0077";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
