import { expect, test } from "bun:test";
import { $ } from "bun";
import ts from "typescript";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import tooling from "./package.json";
import fixture from "../tests/fixtures/model-catalog.json";
import { buildClient } from "./build";

test("standalone npm tarballs include shared discovery, declarations and native loader entrypoints", async () => {
  const directory = await mkdtemp(join(tmpdir(), "fumo-packages-"));
  try {
    const packages = { pi: "@fumo-gateway/pi", opencode: "@fumo-gateway/opencode" };
    const dependencies = Object.fromEntries(Object.entries(tooling.devDependencies).filter(([name]) => !["typescript", "@types/bun"].includes(name)));
    for (const client of ["pi", "opencode"] as const) {
      await buildClient(client);
      const archive = join(directory, `${client}.tgz`);
      await $`${process.execPath} pm pack --ignore-scripts --filename ${archive} --quiet`.cwd(join(import.meta.dir, client)).quiet();
      const entries = (await $`tar -tf ${archive}`.quiet()).stdout.toString();
      expect(entries).toContain(client === "pi" ? "package/dist/index.js" : "package/server.js");
      expect(entries).toContain(`package/dist/${client}/${client === "pi" ? "index" : "server"}.d.ts`);
      for (const excluded of ["node_modules", "catalog.ts", "index.test.ts", "auth.json", "gateway.json"]) expect(entries).not.toContain(excluded);
      dependencies[packages[client]] = `file:${archive}`;
    }
    await Bun.write(join(directory, "package.json"), JSON.stringify({ private: true, type: "module", dependencies }));
    await $`${process.execPath} install --ignore-scripts`.cwd(directory).quiet();

    // This process has only installed tarballs and host dependencies. No linked
    // workspace, sibling catalog source, private auth store or inference network.
    await Bun.write(join(directory, "smoke.ts"), `
      import assert from "node:assert/strict";
      import pi, { createFumoProvider } from "@fumo-gateway/pi";
      import opencode, { createFumoPlugin } from "@fumo-gateway/opencode";
      import { ModelRuntime } from "@earendil-works/pi-coding-agent";
      import { InMemoryModelsStore } from "@earendil-works/pi-ai";
      const registrations = [];
      pi({ registerProvider(provider) { registrations.push(provider); } });
      assert.equal(registrations.length, 1);
      const { loadExtensions, createExtensionRuntime } = await import(new URL("./core/extensions/loader.js", import.meta.resolve("@earendil-works/pi-coding-agent")));
      const host = createExtensionRuntime();
      const loaded = await loadExtensions([import.meta.resolve("@fumo-gateway/pi")], process.cwd(), process.cwd() + "/agent", host);
      assert.deepEqual(loaded.errors, []);
      assert.equal(host.pendingNativeProviderRegistrations.length, 1);
      const { Host } = await import("@opencode/plugin/host");
      const parts = Host.resolve({ name: "@fumo-gateway/opencode", directory: process.cwd() });
      assert.ok(parts.server);
      assert.equal((await Host.load(parts.server)).default.id, "fumo");
      const localDirectory = process.cwd() + "/node_modules/@fumo-gateway/opencode";
      await Bun.write(localDirectory + "/server.ts", 'export default { id: "obsolete" };');
      const probe = 'import { Host } from "@opencode/plugin/host"; console.log(Host.resolve({ directory: process.cwd() + "/node_modules/@fumo-gateway/opencode" }).server)';
      assert.ok(Bun.spawnSync([process.execPath, "-e", probe]).stdout.toString().trim().endsWith("/server.ts"));
      // Home Manager removes precisely this obsolete managed entrypoint.
      await (await import("node:fs/promises")).rm(localDirectory + "/server.ts");
      assert.equal(Bun.spawnSync([process.execPath, "-e", probe]).stdout.toString().trim(), parts.server);
      assert.equal(opencode.id, "fumo");
      assert.equal(createFumoPlugin({ baseURL: "https://gateway.example.test/v1" }).id, "fumo");
      const runtime = await ModelRuntime.create({ authPath: "./fixture-auth.json", modelsPath: null, modelsStore: new InMemoryModelsStore(), refreshOnCreate: false });
      runtime.registerNativeProvider(createFumoProvider({ baseUrl: "https://gateway.example.test/v1" }));
      await runtime.login("fumo", "api_key", { prompt: async ({ type }) => type === "text" ? "" : "fixture-client-key", notify() {} });
      globalThis.fetch = async (url, options) => {
        assert.equal(url, "https://gateway.example.test/v1/models");
        assert.equal(options.headers.Authorization, "Bearer fixture-client-key");
        return Response.json(${JSON.stringify(fixture)});
      };
      const result = await runtime.refresh({ providers: ["fumo"] });
      assert.equal(result.errors.size, 0);
      assert.equal(runtime.getModels("fumo")[0].contextWindow, 272000);
      assert.equal(runtime.getModels("fumo")[0].id, "personal/fast");
    `);
    await $`${process.execPath} smoke.ts`.cwd(directory).quiet();

    const consumer = join(directory, "consumer.mts");
    await Bun.write(consumer, 'import { createFumoProvider } from "@fumo-gateway/pi"; import { createFumoPlugin } from "@fumo-gateway/opencode"; createFumoProvider({ baseUrl: "https://example.test/v1" }); createFumoPlugin({ baseURL: "https://example.test/v1" });');
    const program = ts.createProgram([consumer], { noEmit: true, module: ts.ModuleKind.NodeNext, moduleResolution: ts.ModuleResolutionKind.NodeNext });
    const owned = [consumer, join(directory, "node_modules/@fumo-gateway/pi/"), join(directory, "node_modules/@fumo-gateway/opencode/")];
    // Some host SDK declarations are Bundler-only. Verify our declarations and
    // consumer without treating unrelated upstream SDK diagnostics as Fumo's.
    const diagnostics = ts.getPreEmitDiagnostics(program).filter(({ file }) => file && owned.some((path) => file.fileName.startsWith(path)));
    expect(diagnostics.map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n"))).toEqual([]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 60000);
