import { join } from "node:path";
import { rm } from "node:fs/promises";

export async function buildClient(client: "pi" | "opencode") {
  const directory = join(import.meta.dir, client);
  await rm(join(directory, "dist"), { recursive: true, force: true });
  const entry = join(directory, client === "pi" ? "index.ts" : "server.ts");
  const result = await Bun.build({
    entrypoints: [entry],
    outdir: client === "pi" ? join(directory, "dist") : directory,
    naming: client === "pi" ? "index.js" : "server.js",
    target: "node",
    packages: "external",
  });
  if (!result.success) throw new AggregateError(result.logs, `Cannot build ${client}`);

  // Declarations retain each client's API types; runtime JS includes the shared
  // relative modules but leaves host-provided packages external.
  const types = Bun.spawn([
    process.execPath, join(import.meta.dir, "node_modules/typescript/bin/tsc"), entry,
    "--declaration", "--emitDeclarationOnly", "--outDir", join(directory, "dist"),
    "--rootDir", import.meta.dir, "--module", "ESNext", "--moduleResolution", "Bundler",
    "--target", "ES2022", "--strict", "--skipLibCheck", "--types", "bun",
  ], { cwd: import.meta.dir, stdout: "inherit", stderr: "inherit" });
  if (await types.exited !== 0) throw new Error(`Cannot generate ${client} declarations`);
}

if (import.meta.main) {
  const selected = process.argv[2];
  if (selected && selected !== "pi" && selected !== "opencode") throw new Error("Expected pi or opencode");
  for (const client of ["pi", "opencode"] as const) {
    if (!selected || selected === client) await buildClient(client);
  }
}
