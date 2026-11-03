import { test, expect } from "bun:test";
import { chromium } from "playwright";
import { createServer } from "vite";

test("admin session persists through reload and logs out", async () => {
    const external = process.env.BASE_URL;
    let connected = false;
    let authenticated = false;
    const session = crypto.randomUUID();

    const fixture = external
        ? undefined
        : Bun.serve({
              hostname: "127.0.0.1",
              port: 0,
              fetch: async (request) => {
                  const path = new URL(request.url).pathname;
                  const cookie =
                      request.headers.get("cookie") ===
                      `fumo_admin_session=${session}`;
                  if (request.headers.get("x-requested-with") !== "fumo-admin")
                      return Response.json(
                          { error: "forbidden" },
                          { status: 403 },
                      );

                  if (path === "/admin/api/session") {
                      if (request.method === "DELETE") {
                          authenticated = false;
                          return Response.json(
                              { status: "signed_out" },
                              {
                                  headers: {
                                      "Set-Cookie":
                                          "fumo_admin_session=; Path=/admin/; HttpOnly; SameSite=Strict; Max-Age=0",
                                  },
                              },
                          );
                      }
                      if (
                          request.headers.get("authorization") !==
                          "Bearer smoke-key"
                      )
                          return Response.json(
                              { error: "unauthorized" },
                              { status: 401 },
                          );
                      authenticated = true;
                      return Response.json(
                          { status: "authenticated" },
                          {
                              headers: {
                                  "Set-Cookie": `fumo_admin_session=${session}; Path=/admin/; HttpOnly; SameSite=Strict`,
                              },
                          },
                      );
                  }
                  if (!authenticated || !cookie)
                      return Response.json(
                          { error: "unauthorized" },
                          { status: 401 },
                      );

                  if (path.endsWith("/auth/disconnect")) {
                      connected = false;
                      return Response.json({ status: "login_required" });
                  }
                  if (path.endsWith("/auth/start"))
                      return Response.json({
                          authorization_url: "https://example.com/authorize",
                          expires_in: 300,
                      });
                  if (path.endsWith("/auth/complete")) {
                      // SAFETY: Only this test's callback form calls the fixture, sending a JSON object with callback_url.
                      const body = (await request.json()) as {
                          callback_url: string;
                      };
                      expect(body.callback_url).toBe("http://localhost/callback?code=fixture");
                      connected = true;
                      return Response.json({ status: "connected" });
                  }
                  return Response.json({
                      accounts: [
                          {
                              id: "codex",
                              provider: "codex",
                              configured: false,
                              pending: false,
                              status: connected
                                  ? "connected"
                                  : "login_required",
                          },
                      ],
                  });
              },
          });

    const vite = external
        ? undefined
        : await createServer({
              server: {
                  host: "127.0.0.1",
                  port: 0,
                  proxy: { "/admin/api": `http://127.0.0.1:${fixture!.port}` },
              },
          });
    await vite?.listen();

    const browser = await chromium.launch({
        executablePath: process.env.CHROME_PATH || undefined,
    });
    try {
        const page = await browser.newPage();
        await page.goto(external ?? `${vite!.resolvedUrls!.local[0]}admin/`);
        await page
            .getByLabel("Admin key", { exact: true })
            .fill(process.env.ADMIN_KEY ?? "smoke-key");
        await page.getByRole("button", { name: "Unlock", exact: true }).click();
        await page
            .getByRole("button", { name: "Refresh", exact: true })
            .waitFor();
        expect(
            await page.getByRole("heading", { name: "Fumo admin" }).count(),
        ).toBe(1);
        await page.reload();
        await page
            .getByRole("button", { name: "Log out", exact: true })
            .waitFor();
        if (!external) {
            await page.getByRole("button", { name: "Log in", exact: true }).click();
            await page.getByRole("link", { name: "Open authorization page" }).waitFor();
            await page.getByLabel("Callback URL", { exact: true })
                .fill("http://localhost/callback?code=fixture");
            await page.getByRole("button", { name: "Complete", exact: true }).click();
            await page.getByRole("button", { name: "Disconnect", exact: true }).waitFor();
            expect(await page.getByText("Connected", { exact: true }).count()).toBe(1);
            await page.getByRole("button", { name: "Disconnect", exact: true }).click();
            await page.getByText("Login required", { exact: true }).waitFor();
        }

        await page
            .getByRole("button", { name: "Log out", exact: true })
            .click();
        await page.getByRole("button", { name: "Unlock", exact: true }).waitFor();
        await page.reload();
        await page.getByRole("button", { name: "Unlock", exact: true }).waitFor();
    } finally {
        await browser.close();
        await vite?.close();
        fixture?.stop(true);
    }
}, 60000);
