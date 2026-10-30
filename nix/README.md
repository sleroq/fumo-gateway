# NixOS module

Add the flake input:

```nix
inputs.fumo-gateway.url = "https://github.com/sleroq/fumo-gateway/archive/refs/heads/main.tar.gz";
```

Include the module in `nixosSystem.modules`:

```nix
modules = [
  inputs.fumo-gateway.nixosModules.default
  ./configuration.nix
];
```

With agenix configured, add this host module:

```nix
{ config, ... }:
{
  age.secrets.fumo-gateway-env.file = ./secrets/fumo-gateway.env.age;

  services.fumo-gateway = {
    enable = true;
    environmentFile = config.age.secrets.fumo-gateway-env.path;
    settings = {
      clients.pi.key_env = "FUMO_PI_KEY";
      upstreams.codex = {
        base_url = "https://api.openai.com/v1";
        auth.provider = "codex";
      };
    };
  };
}
```

Put `FUMO_PI_KEY` and `FUMO_ADMIN_KEY` in the encrypted file as `NAME=value` lines.

## ChatGPT login

With the gateway running, tunnel the admin interface:

```sh
ssh -N -L 8318:127.0.0.1:8318 your-server
```

Open `http://127.0.0.1:8318/admin/`, unlock with `FUMO_ADMIN_KEY`, and connect
Codex through the ChatGPT sign-in flow.

## Reverse proxy

Keep admin/health endpoints private. Here are tested examples:

### Caddy

```nix
services.caddy = {
  enable = true;
  virtualHosts."fumo.example.com".extraConfig = ''
    @inference path /v1/models /v1/responses /v1/chat/completions
    handle @inference {
      reverse_proxy 127.0.0.1:8318
    }
    handle {
      respond 404
    }
  '';
};
```

### nginx

```nix
security.acme = {
  acceptTerms = true;
  defaults.email = "admin@example.com";
};
services.nginx = {
  enable = true;
  virtualHosts."fumo.example.com" = {
    enableACME = true;
    forceSSL = true;
    locations."~ ^/v1/(models|responses|chat/completions)$" = {
      proxyPass = "http://127.0.0.1:8318";
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 3600s;
      '';
    };
  };
};
```
