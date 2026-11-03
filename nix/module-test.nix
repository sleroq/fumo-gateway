{
  self,
  nixpkgs,
  pkgs,
}:
let
  inherit (pkgs) lib;
  package = pkgs.writeShellScriptBin "fumo-gateway" "exit 0";
  evaluate =
    settings:
    (nixpkgs.lib.nixosSystem {
      modules = [
        self.nixosModules.default
        {
          nixpkgs.pkgs = pkgs;
          services.fumo-gateway = {
            enable = true;
            inherit package;
          }
          // settings;
        }
      ];
    }).config;
  defaults = evaluate { };
  configured = evaluate {
    environmentFile = "/run/secrets/fumo-gateway.env";
    settings = {
      listen = "127.0.0.1:9000";
      proxy_env = "FUMO_PROXY";
      clients.test.key_env = "FUMO_TEST_KEY";
    };
  };
  cfg = configured.services.fumo-gateway;
  service = configured.systemd.services.fumo-gateway.serviceConfig;
  checks = [
    {
      assertion = service.ExecStart == "${lib.getExe package} --config ${cfg.configFile}";
      message = "fumo-gateway must start the configured package with its generated config";
    }
    {
      assertion =
        service.StateDirectory == "fumo-gateway"
        && service.StateDirectoryMode == "0700"
        && service.WorkingDirectory == "/var/lib/fumo-gateway";
      message = "fumo-gateway must use a private persistent state directory";
    }
    {
      assertion =
        service.User == "fumo-gateway"
        && service.Group == "fumo-gateway"
        && configured.users.users.fumo-gateway.isSystemUser
        && configured.users.users.fumo-gateway.group == "fumo-gateway"
        && configured.users.users.fumo-gateway.home == "/var/lib/fumo-gateway"
        && configured.users.groups ? fumo-gateway;
      message = "fumo-gateway must run as its dedicated system user and group";
    }
    {
      assertion =
        service.EnvironmentFile == [ "/run/secrets/fumo-gateway.env" ]
        && defaults.systemd.services.fumo-gateway.serviceConfig.EnvironmentFile == [ ];
      message = "fumo-gateway must forward the optional environment file to systemd";
    }
  ];
in
assert lib.asserts.assertMsg (lib.all (
  check: lib.asserts.assertMsg check.assertion check.message
) checks) "fumo-gateway module checks failed";
pkgs.runCommand "fumo-gateway-module-test" { nativeBuildInputs = [ pkgs.jq ]; } ''
  jq -e '
    .listen == "127.0.0.1:9000" and
    .proxy_env == "FUMO_PROXY" and
    .clients.test.key_env == "FUMO_TEST_KEY"
  ' ${cfg.configFile}
  jq -e '.proxy_env == null' ${defaults.services.fumo-gateway.configFile}
  mkdir -p "$out"
  cp ${cfg.configFile} "$out/config.json"
  cp ${defaults.services.fumo-gateway.configFile} "$out/default-config.json"
''
