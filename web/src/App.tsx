import {
    createSignal,
    createStore,
    For,
    onSettled,
    reconcile,
    Show,
} from "solid-js";

type Account = {
    id: string;
    provider: "codex";
    status: "connected" | "login_required";
    configured: boolean;
};
type Authorization = { id: string; url: string; expires: number };
const secure =
    location.protocol === "https:" ||
    location.hostname === "localhost" ||
    location.hostname === "[::1]" ||
    /^127(?:\.\d{1,3}){3}$/.test(location.hostname);

export default function App() {
    const [enabled, setEnabled] = createSignal<boolean>();
    const [key, setKey] = createSignal("");
    const [unlocked, setUnlocked] = createSignal(false);
    const [checkingSession, setCheckingSession] = createSignal(secure);
    const [loadingAccounts, setLoadingAccounts] = createSignal(false);
    const [accounts, setAccounts] = createStore<Account[]>([]);
    const [busy, setBusy] = createSignal(false);
    const [error, setError] = createSignal("");
    const [notice, setNotice] = createSignal("");
    const [authorization, setAuthorization] = createSignal<Authorization>();
    const [callback, setCallback] = createSignal("");

    function clearAuthentication() {
        setKey("");
        setUnlocked(false);
        setAccounts((draft) => {
            draft.length = 0;
        });
        setAuthorization(undefined);
        setCallback("");
        setNotice("");
    }
    async function request<T>(
        path: string,
        body?: Record<string, string>,
        method: "GET" | "POST" | "DELETE" = body ? "POST" : "GET",
        adminKey?: string,
    ): Promise<T> {
        const headers = new Headers({ "X-Requested-With": "fumo-admin" });
        if (adminKey) headers.set("Authorization", `Bearer ${adminKey}`);
        if (body) headers.set("Content-Type", "application/json");
        const options: RequestInit = {
            method,
            cache: "no-store",
            credentials: "same-origin",
            redirect: "error",
            headers,
        };
        if (body) options.body = JSON.stringify(body);
        const response = await fetch(`/admin/api/${path}`, options);
        if (response.status === 401) clearAuthentication();
        const data = await response.json();
        if (response.status === 503 && data.error === "admin_disabled") {
            clearAuthentication();
            setEnabled(false);
        } else if (response.ok || response.status === 401) {
            setEnabled(true);
        }
        if (!response.ok)
            throw new Error(
                /^[a-z_]+$/.test(String(data.error))
                    ? String(data.error).replaceAll("_", " ")
                    : "Request failed.",
                { cause: response.status },
            );
        // SAFETY: Successful responses follow the gateway account API contract; T is supplied only by its endpoint callers.
        return data as T;
    }
    async function perform(work: () => Promise<void>) {
        setBusy(true);
        setError("");
        setNotice("");
        try {
            await work();
        } catch (failure) {
            if (enabled() === false) return;
            setError(
                failure instanceof TypeError
                    ? "Cannot reach the gateway."
                    : failure instanceof Error
                      ? failure.message
                      : "Request failed.",
            );
        } finally {
            setBusy(false);
        }
    }
    async function load() {
        setLoadingAccounts(true);
        try {
            const data = await request<{ accounts: Account[] }>("accounts");
            setAccounts((draft) => {
                reconcile(data.accounts, "id")(draft);
            });
            setUnlocked(true);
        } finally {
            setLoadingAccounts(false);
        }
    }
    async function unlock() {
        await request("session", undefined, "POST", key());
        setKey("");
        await load();
    }
    async function logout() {
        await perform(async () => {
            await request("session", undefined, "DELETE");
            clearAuthentication();
        });
    }
    onSettled(() => {
        if (!secure) return;
        void perform(async () => {
            try {
                await load();
            } catch (failure) {
                if (!(failure instanceof Error && failure.cause === 401))
                    throw failure;
            } finally {
                setCheckingSession(false);
            }
        });
    });
    async function start(account: Account) {
        await perform(async () => {
            const data = await request<{
                authorization_url: string;
                expires_in: number;
            }>(`accounts/${encodeURIComponent(account.id)}/auth/start`, {});
            const url = new URL(data.authorization_url);
            if (url.protocol !== "https:")
                throw new Error(
                    "The gateway returned an unsafe authorization link.",
                );
            setAuthorization({
                id: account.id,
                url: url.href,
                expires: Date.now() + data.expires_in * 1000,
            });
            setCallback("");
        });
    }
    async function disconnect(account: Account) {
        await perform(async () => {
            await request(
                `accounts/${encodeURIComponent(account.id)}/auth/disconnect`,
                {},
            );
            if (authorization()?.id === account.id) {
                setAuthorization(undefined);
                setCallback("");
            }
            await load();
        });
    }
    async function complete(event: SubmitEvent) {
        event.preventDefault();
        const current = authorization();
        if (!current) return;
        await perform(async () => {
            if (Date.now() >= current.expires)
                throw new Error(
                    "Authorization expired. Start a new connection.",
                );
            await request(
                `accounts/${encodeURIComponent(current.id)}/auth/complete`,
                {
                    callback_url: callback(),
                },
            );
            setCallback("");
            setAuthorization(undefined);
            setNotice("Connected.");
            await load();
        });
    }

    return (
        <main>
            <header>
                <h1>
                    <img src="/admin/logo.svg" width="32" height="32" alt="" />
                    Fumo admin
                </h1>
                <Show when={unlocked()}>
                    <button
                        class="icon-button"
                        aria-label="Log out"
                        title="Log out"
                        disabled={busy()}
                        onClick={logout}
                    >
                        <svg
                            width="20"
                            height="20"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="2"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            aria-hidden="true"
                        >
                            <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9" />
                        </svg>
                    </button>
                </Show>
            </header>
            <Show when={enabled() === false}>
                <p>
                    Admin is disabled. To enable it, add{" "}
                    <code>{'{"admin":{"key_env":"FUMO_ADMIN_KEY"}}'}</code> to
                    your config, set the <code>FUMO_ADMIN_KEY</code> environment
                    variable, and restart the gateway.
                </p>
            </Show>
            <Show when={!secure && enabled() !== false}>
                <p role="alert">
                    Use HTTPS or an SSH tunnel before entering the admin key.
                </p>
            </Show>
            <Show
                when={
                    secure &&
                    !checkingSession() &&
                    enabled() === true &&
                    !unlocked()
                }
            >
                <form
                    onSubmit={(event) => {
                        event.preventDefault();
                        void perform(unlock);
                    }}
                >
                    <label for="key">Admin key</label>
                    <input
                        id="key"
                        type="password"
                        autocomplete="off"
                        required
                        value={key()}
                        onInput={(event) => setKey(event.currentTarget.value)}
                        disabled={busy()}
                    />
                    <button disabled={busy()} type="submit">
                        {busy() ? "Unlocking…" : "Unlock"}
                    </button>
                </form>
            </Show>
            <div role="status">{notice()}</div>
            <Show when={error()}>
                <p role="alert">Error: {error()}</p>
            </Show>
            <Show
                when={(checkingSession() && enabled() !== false) || unlocked()}
            >
                <section
                    aria-label="Accounts"
                    aria-busy={
                        checkingSession() || loadingAccounts()
                            ? "true"
                            : "false"
                    }
                >
                    <header>
                        <h2>Accounts</h2>
                        <button
                            class="icon-button"
                            aria-label="Refresh"
                            title="Refresh"
                            disabled={busy() || checkingSession()}
                            onClick={() => void perform(load)}
                        >
                            <svg
                                width="20"
                                height="20"
                                viewBox="0 0 24 24"
                                fill="none"
                                stroke="currentColor"
                                stroke-width="2"
                                stroke-linecap="round"
                                stroke-linejoin="round"
                                aria-hidden="true"
                            >
                                <path d="M3 12a9 9 0 0 1 15.36-6.36L21 8M21 3v5h-5M21 12a9 9 0 0 1-15.36 6.36L3 16M8 16H3v5" />
                            </svg>
                        </button>
                    </header>
                    <ul
                        class={{
                            "accounts-loading":
                                checkingSession() || loadingAccounts(),
                        }}
                        aria-hidden={
                            checkingSession() || loadingAccounts()
                                ? "true"
                                : "false"
                        }
                    >
                        <For
                            each={accounts}
                            fallback={
                                <Show
                                    when={checkingSession()}
                                    fallback={<li>No accounts.</li>}
                                >
                                    <li class="account">
                                        <div class="account-info">
                                            <strong>Loading accounts</strong>
                                            <div>Checking session</div>
                                        </div>
                                        <button disabled>Log in</button>
                                    </li>
                                </Show>
                            }
                        >
                            {(account) => (
                                <li class="account">
                                    <div class="account-info">
                                        <strong>{account.id}</strong>
                                        <div>
                                            {account.status === "connected"
                                                ? "Connected"
                                                : "Login required"}
                                        </div>
                                        <Show when={!account.configured}>
                                            <small>
                                                Not configured for inference
                                            </small>
                                        </Show>
                                    </div>
                                    <Show
                                        when={account.status === "connected"}
                                        fallback={
                                            <button
                                                disabled={busy()}
                                                onClick={() =>
                                                    void start(account)
                                                }
                                            >
                                                Log in
                                            </button>
                                        }
                                    >
                                        <button
                                            disabled={busy()}
                                            onClick={() =>
                                                void disconnect(account)
                                            }
                                        >
                                            Disconnect
                                        </button>
                                    </Show>
                                </li>
                            )}
                        </For>
                    </ul>
                </section>
                <Show when={authorization()}>
                    {(current) => (
                        <section>
                            <h2>Log in to {current().id}</h2>
                            <p>
                                Sign in, then paste the final callback URL—even
                                if it fails to load. Expires in 5 minutes.
                            </p>
                            <a
                                href={current().url}
                                target="_blank"
                                rel="noopener noreferrer"
                            >
                                Open authorization page
                            </a>
                            <form onSubmit={(event) => void complete(event)}>
                                <label for="callback">Callback URL</label>
                                <input
                                    id="callback"
                                    type="url"
                                    autocomplete="off"
                                    spellcheck={false}
                                    required
                                    value={callback()}
                                    onInput={(event) =>
                                        setCallback(event.currentTarget.value)
                                    }
                                    disabled={busy()}
                                />
                                <div class="actions">
                                    <button type="submit" disabled={busy()}>
                                        {busy() ? "Connecting…" : "Complete"}
                                    </button>
                                    <button
                                        type="button"
                                        disabled={busy()}
                                        onClick={() => {
                                            setAuthorization(undefined);
                                            setCallback("");
                                            setNotice("");
                                        }}
                                    >
                                        Cancel
                                    </button>
                                </div>
                            </form>
                        </section>
                    )}
                </Show>
            </Show>
        </main>
    );
}
