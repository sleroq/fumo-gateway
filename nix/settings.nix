{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options = {
    listen = mkOption {
      type = types.nonEmptyStr;
      default = "127.0.0.1:8318";
      example = "[::1]:8318";
      description = "Literal IPv4 or bracketed IPv6 address and port. Keep this on loopback when using a reverse proxy.";
    };

    admin = mkOption {
      type = types.nullOr (
        types.submodule {
          options.key_env = mkOption {
            type = types.nonEmptyStr;
            default = "FUMO_ADMIN_KEY";
            description = "Environment variable containing the admin key, not the key itself.";
          };
        }
      );
      default = null;
      description = ''
        Override the admin key environment variable. An object requires that
        variable to be set. When null, FUMO_ADMIN_KEY still enables administration
        if set; null does not disable an existing admin key.
      '';
    };

    clients = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.key_env = mkOption {
            type = types.nonEmptyStr;
            example = "FUMO_PI_KEY";
            description = "Environment variable containing this client's inference bearer key. Must differ from other client keys and the admin key.";
          };
        }
      );
      default = { };
      description = "Named inference clients. Secret values belong in services.fumo-gateway.environmentFile.";
    };

    upstreams = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            base_url = mkOption {
              type = types.nonEmptyStr;
              example = "https://api.openai.com/v1";
              description = ''
                HTTP(S) API root without userinfo, query, or fragment. Codex
                authentication requires https://api.openai.com/v1.
              '';
            };

            aliases = mkOption {
              type = types.attrsOf types.nonEmptyStr;
              default = { };
              example = {
                fast = "gpt-5";
              };
              description = "Local model aliases mapped to native upstream model IDs. Requests perform one alias lookup.";
            };

            auth = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    provider = mkOption {
                      type = types.enum [
                        "codex"
                        "api_key"
                      ];
                      description = "Use Sign in with ChatGPT (codex) or an API key from the environment (api_key).";
                    };

                    key_env = mkOption {
                      type = types.nullOr types.nonEmptyStr;
                      default = null;
                      example = "OPENAI_API_KEY";
                      description = "Environment variable containing the upstream API key. Required for api_key; must be null for codex.";
                    };

                    credentials_dir = mkOption {
                      type = types.nullOr types.nonEmptyStr;
                      default = null;
                      example = "/var/lib/fumo-gateway/credentials";
                      description = ''
                        Private OAuth credential directory for codex. Null uses
                        the gateway's default state directory; relative paths
                        resolve from /var/lib/fumo-gateway. Must be null for api_key.
                      '';
                    };
                  };
                }
              );
              default = null;
              description = "Upstream authentication. Null forwards requests without upstream authentication.";
            };
          };
        }
      );
      default = { };
      description = "Named upstreams. Names use letters, digits, underscores, or hyphens and become model namespaces, such as codex/gpt-5.";
    };
  };
}
