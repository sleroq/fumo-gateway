import { test, expect } from "bun:test";
import { chromium } from "playwright";
import { createServer } from "vite";

test("admin session survives reload and signs out on logout or unauthorized responses", async () => {
    const external = process.env.BASE_URL;
    let connected = false;
    let disconnectFails = false;
    let expired = false;
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
                      if (disconnectFails)
                          return Response.json(
                              { error: "credential_save_failed" },
                              { status: 500 },
                          );
                      connected = false;
                      return Response.json({ status: "login_required" });
                  }
                  if (path.endsWith("/auth/start"))
                      return Response.json({
                          authorization_url: "https://example.com/authorize",
                          expires_in: expired ? -1 : 300,
                      });
                  if (path.endsWith("/auth/complete")) {
                      // SAFETY: Only this test's callback form calls the fixture, sending a JSON object with callback_url.
                      const body = (await request.json()) as {
                          callback_url: string;
                      };
                      if (
                          body.callback_url !==
                          "http://localhost/callback?code=fixture"
                      )
                          return Response.json(
                              { error: "invalid_callback" },
                              { status: 400 },
                          );
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
        const errors: string[] = [];
        let bearerOnAccounts = false;
        page.on("pageerror", () => errors.push("Browser runtime error"));
        page.on("request", (request) => {
            if (
                new URL(request.url()).pathname === "/admin/api/accounts" &&
                request.headers().authorization
            )
                bearerOnAccounts = true;
        });

        await page.goto(external ?? `${vite!.resolvedUrls!.local[0]}admin/`);
        await page.getByLabel("Admin key", { exact: true }).fill("incorrect");
        await page.getByRole("button", { name: "Unlock", exact: true }).click();
        await page.getByRole("alert").waitFor();

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
        expect(
            await page.locator('link[rel="icon"]').getAttribute("href"),
        ).toBe("/admin/logo.svg");
        expect(
            (
                await page.request.get(
                    new URL("/admin/logo.svg", page.url()).href,
                )
            ).ok(),
        ).toBe(true);

        const cookie = (await page.context().cookies()).find(
            (value) => value.name === "fumo_admin_session",
        );
        expect(cookie?.httpOnly).toBe(true);
        expect(cookie?.sameSite).toBe("Strict");
        expect(cookie?.path).toBe("/admin/");
        expect(cookie?.expires).toBe(-1);
        expect(
            await page.evaluate(() =>
                document.cookie.includes("fumo_admin_session"),
            ),
        ).toBe(false);
        expect(
            await page.evaluate(
                () => localStorage.length + sessionStorage.length,
            ),
        ).toBe(0);

        await page.reload();
        await page
            .getByRole("button", { name: "Log out", exact: true })
            .waitFor();
        for (const name of ["Log out", "Refresh"]) {
            const button = page.getByRole("button", { name, exact: true });
            expect((await button.textContent())?.trim()).toBe("");
            expect(
                await button.locator('svg[aria-hidden="true"]').count(),
            ).toBe(1);
        }
        expect(
            await page.getByLabel("Admin key", { exact: true }).count(),
        ).toBe(0);

        const login = page
            .getByRole("button", { name: "Log in", exact: true })
            .first();
        if (await login.count()) {
            await login.click();
            await page
                .getByRole("link", { name: "Open authorization page" })
                .waitFor();
        }
        if (!external) {
            expect(
                await page
                    .getByText("Not configured", { exact: false })
                    .count(),
            ).toBe(1);
            await page
                .getByLabel("Callback URL", { exact: true })
                .fill("http://localhost/callback?code=invalid");
            await page
                .getByRole("button", { name: "Complete", exact: true })
                .click();
            await page
                .getByRole("alert")
                .filter({ hasText: "invalid callback" })
                .waitFor();

            await page
                .getByLabel("Callback URL", { exact: true })
                .fill("http://localhost/callback?code=fixture");
            await page
                .getByRole("button", { name: "Complete", exact: true })
                .click();
            await page
                .getByRole("button", { name: "Disconnect", exact: true })
                .waitFor();
            expect(
                await page.getByText("Connected", { exact: true }).count(),
            ).toBe(1);
            expect(
                await page.getByLabel("Callback URL", { exact: true }).count(),
            ).toBe(0);
            expect(
                await page
                    .getByText("Not configured", { exact: false })
                    .count(),
            ).toBe(1);

            disconnectFails = true;
            await page
                .getByRole("button", { name: "Disconnect", exact: true })
                .click();
            await page
                .getByRole("alert")
                .filter({ hasText: "credential save failed" })
                .waitFor();
            expect(
                await page.getByText("Connected", { exact: true }).count(),
            ).toBe(1);
            disconnectFails = false;
            await page
                .getByRole("button", { name: "Disconnect", exact: true })
                .click();
            await page.getByText("Login required", { exact: true }).waitFor();
            expect(
                await page
                    .getByRole("button", { name: "Disconnect", exact: true })
                    .count(),
            ).toBe(0);
            expect(
                await page
                    .getByRole("button", { name: "Log out", exact: true })
                    .count(),
            ).toBe(1);
            await page.reload();
            await page.getByText("Login required", { exact: true }).waitFor();

            expired = true;
            await page
                .getByRole("button", { name: "Log in", exact: true })
                .click();
            await page
                .getByLabel("Callback URL", { exact: true })
                .fill("http://localhost/callback?code=fixture");
            await page
                .getByRole("button", { name: "Complete", exact: true })
                .click();
            await page
                .getByRole("alert")
                .filter({ hasText: "Authorization expired" })
                .waitFor();

            expired = false;
            for (const action of ["Refresh", "Log in", "Complete"]) {
                await page
                    .getByRole("button", { name: "Log in", exact: true })
                    .click();
                await page
                    .getByLabel("Callback URL", { exact: true })
                    .fill("http://localhost/callback?code=fixture");
                authenticated = false;
                await page
                    .getByRole("button", { name: action, exact: true })
                    .click();
                await page
                    .getByRole("button", { name: "Unlock", exact: true })
                    .waitFor();
                expect(
                    await page
                        .getByLabel("Admin key", { exact: true })
                        .inputValue(),
                ).toBe("");
                expect(
                    await page
                        .getByRole("button", { name: "Log out", exact: true })
                        .count(),
                ).toBe(0);
                expect(
                    await page
                        .getByRole("heading", { name: "Accounts", exact: true })
                        .count(),
                ).toBe(0);
                expect(
                    await page
                        .getByRole("link", { name: "Open authorization page" })
                        .count(),
                ).toBe(0);
                expect(
                    await page
                        .getByLabel("Callback URL", { exact: true })
                        .count(),
                ).toBe(0);

                await page
                    .getByLabel("Admin key", { exact: true })
                    .fill("smoke-key");
                await page
                    .getByRole("button", { name: "Unlock", exact: true })
                    .click();
                await page
                    .getByRole("button", { name: "Refresh", exact: true })
                    .waitFor();
                expect(
                    await page
                        .getByLabel("Callback URL", { exact: true })
                        .count(),
                ).toBe(0);
            }
        }

        await page
            .getByRole("button", { name: "Log out", exact: true })
            .click();
        expect(
            await page.getByLabel("Admin key", { exact: true }).inputValue(),
        ).toBe("");
        expect(
            await page.evaluate(
                () => localStorage.length + sessionStorage.length,
            ),
        ).toBe(0);
        await page.reload();
        await page
            .getByRole("button", { name: "Unlock", exact: true })
            .waitFor();
        expect(
            await page
                .getByRole("button", { name: "Log out", exact: true })
                .count(),
        ).toBe(0);
        expect(bearerOnAccounts).toBe(false);
        expect(errors).toEqual([]);
    } finally {
        await browser.close();
        await vite?.close();
        fixture?.stop(true);
    }
}, 60000);

test.skipIf(!!process.env.BASE_URL)(
    "session checks never flash the login form and refresh skeletons preserve account layout",
    async () => {
        let releaseResponse!: () => void;
        let respond: Promise<void>;
        function holdResponse() {
            respond = new Promise<void>((resolve) => {
                releaseResponse = resolve;
            });
        }
        holdResponse();
        const fixture = Bun.serve({
            hostname: "127.0.0.1",
            port: 0,
            fetch: async () => {
                await respond;
                return Response.json({
                    accounts: [
                        {
                            id: "codex",
                            provider: "codex",
                            configured: false,
                            status: "connected",
                        },
                        {
                            id: "secondary",
                            provider: "codex",
                            configured: true,
                            status: "login_required",
                        },
                    ],
                });
            },
        });
        const vite = await createServer({
            server: {
                host: "127.0.0.1",
                port: 0,
                proxy: { "/admin/api": `http://127.0.0.1:${fixture.port}` },
            },
        });
        await vite.listen();
        const browser = await chromium.launch({
            executablePath: process.env.CHROME_PATH || undefined,
        });
        try {
            const page = await browser.newPage();
            await page.addInitScript(() => {
                new MutationObserver((records) => {
                    for (const record of records) {
                        for (const node of record.addedNodes) {
                            if (
                                node instanceof Element &&
                                (node.matches("#key") ||
                                    node.querySelector("#key"))
                            ) {
                                document.documentElement.dataset.loginSeen =
                                    "true";
                            }
                        }
                    }
                }).observe(document, { childList: true, subtree: true });
            });
            const region = page.getByRole("region", {
                name: "Accounts",
                exact: true,
            });
            const rows = page.locator(".account");
            const refresh = page.getByRole("button", {
                name: "Refresh",
                exact: true,
            });
            await page.goto(`${vite.resolvedUrls!.local[0]}admin/`);
            await page.locator(".accounts-loading").waitFor();
            expect(await region.getAttribute("aria-busy")).toBe("true");
            expect(
                await page.getByLabel("Admin key", { exact: true }).count(),
            ).toBe(0);
            releaseResponse();
            await page
                .getByRole("button", { name: "Disconnect", exact: true })
                .waitFor();

            holdResponse();
            await page.reload();
            await page.locator(".accounts-loading").waitFor();
            expect(
                await page.getByLabel("Admin key", { exact: true }).count(),
            ).toBe(0);
            releaseResponse();
            await page
                .getByRole("button", { name: "Disconnect", exact: true })
                .waitFor();
            expect(
                await page.evaluate(
                    () => document.documentElement.dataset.loginSeen,
                ),
            ).toBeUndefined();

            const firstRow = await rows.first().elementHandle();
            const before = await rows.evaluateAll((elements) =>
                elements.map((element) => {
                    const { x, y, width, height } =
                        element.getBoundingClientRect();
                    return { x, y, width, height };
                }),
            );
            holdResponse();
            await refresh.click();
            await page.locator(".accounts-loading").waitFor();
            expect(await region.getAttribute("aria-busy")).toBe("true");
            expect(await refresh.isDisabled()).toBe(true);
            expect(
                await page.getByText("Working…", { exact: true }).count(),
            ).toBe(0);
            expect(
                await rows.evaluateAll((elements) =>
                    elements.map((element) => {
                        const { x, y, width, height } =
                            element.getBoundingClientRect();
                        return { x, y, width, height };
                    }),
                ),
            ).toEqual(before);
            expect(
                await rows
                    .first()
                    .locator("strong")
                    .evaluate((element) => getComputedStyle(element).color),
            ).toBe("rgba(0, 0, 0, 0)");
            releaseResponse();
            await page
                .locator(".accounts-loading")
                .waitFor({ state: "detached" });
            expect(await region.getAttribute("aria-busy")).toBe("false");
            expect(
                await page
                    .getByRole("button", { name: "Disconnect", exact: true })
                    .isEnabled(),
            ).toBe(true);
            expect(
                await rows.evaluateAll((elements) =>
                    elements.map((element) => {
                        const { x, y, width, height } =
                            element.getBoundingClientRect();
                        return { x, y, width, height };
                    }),
                ),
            ).toEqual(before);
            expect(
                await page.evaluate(
                    (element) => element === document.querySelector(".account"),
                    firstRow,
                ),
            ).toBe(true);
            expect(
                await page.evaluate(
                    () => document.documentElement.dataset.loginSeen,
                ),
            ).toBeUndefined();
        } finally {
            releaseResponse();
            await browser.close();
            await vite.close();
            fixture.stop(true);
        }
    },
    60000,
);

test.skipIf(!!process.env.BASE_URL)(
    "disabled admin shows setup instructions without offering a key input",
    async () => {
        const requests: string[] = [];
        let reportRequest!: () => void;
        let releaseResponse!: () => void;
        const received = new Promise<void>((resolve) => {
            reportRequest = resolve;
        });
        const respond = new Promise<void>((resolve) => {
            releaseResponse = resolve;
        });
        const fixture = Bun.serve({
            hostname: "127.0.0.1",
            port: 0,
            fetch: async (request) => {
                requests.push(new URL(request.url).pathname);
                reportRequest();
                await respond;
                return Response.json(
                    { error: "admin_disabled" },
                    { status: 503 },
                );
            },
        });
        const vite = await createServer({
            server: {
                host: "127.0.0.1",
                port: 0,
                proxy: { "/admin/api": `http://127.0.0.1:${fixture.port}` },
            },
        });
        await vite.listen();
        const browser = await chromium.launch({
            executablePath: process.env.CHROME_PATH || undefined,
        });
        try {
            const page = await browser.newPage();
            await page.goto(`${vite.resolvedUrls!.local[0]}admin/`);
            await received;
            expect(
                await page.getByLabel("Admin key", { exact: true }).count(),
            ).toBe(0);
            expect(
                await page
                    .getByRole("button", { name: "Unlock", exact: true })
                    .count(),
            ).toBe(0);
            releaseResponse();
            await page
                .getByText("Admin is disabled.", { exact: false })
                .waitFor();
            expect(await page.locator("code").first().textContent()).toBe(
                '{"admin":{"key_env":"FUMO_ADMIN_KEY"}}',
            );
            expect(await page.locator("input").count()).toBe(0);
            expect(await page.getByRole("alert").count()).toBe(0);
            await page.reload();
            await page
                .getByText("Admin is disabled.", { exact: false })
                .waitFor();
            expect(await page.locator("input").count()).toBe(0);
            expect(requests).toEqual([
                "/admin/api/accounts",
                "/admin/api/accounts",
            ]);
        } finally {
            releaseResponse();
            await browser.close();
            await vite.close();
            fixture.stop(true);
        }
    },
    60000,
);
