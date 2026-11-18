// Tests for the Pi statusline update notice. Run via: bash tests/run.sh
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import statuslineExtension, {
	checkForUpdate,
	formatUpdateCache,
	gitBlobSha,
	isUpdateCheckDue,
	parseTreeShas,
	parseUpdateCache,
	updateNoticeLine,
} from "../statusline.ts";

const STALE_SHA = "a".repeat(40);
const SH_SHA = "c".repeat(40);
const INTERVAL_S = 21_600;
const TREE_URL = "https://example.invalid/tree";

type Fixture = { dir: string; ownPath: string; ownSha: string; cacheDir: string };
const dirs: string[] = [];

afterEach(async () => {
	await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function fixture(): Promise<Fixture> {
	const dir = await mkdtemp(join(tmpdir(), "statusline-update-"));
	dirs.push(dir);
	const ownPath = join(dir, "statusline.ts");
	await writeFile(ownPath, "export default function statuslineExtension() {}\n");
	return { dir, ownPath, ownSha: gitBlobSha(await readFile(ownPath)), cacheDir: join(dir, "cache") };
}

async function seedCache(cacheDir: string, tsSha: string, stampSeconds: number | string): Promise<void> {
	await mkdir(cacheDir, { recursive: true });
	await writeFile(join(cacheDir, "update-master"), `${SH_SHA} statusline.sh\n${tsSha} statusline.ts\n`);
	await writeFile(join(cacheDir, "update-checked"), `${stampSeconds}\n`);
}

function fakeFetch(respond: () => Promise<Response>) {
	const calls: unknown[] = [];
	const impl = (async (...args: unknown[]) => {
		calls.push(args);
		return respond();
	}) as typeof fetch;
	return { impl, calls };
}

function treeResponse(tsSha: string): Promise<Response> {
	const tree = [
		{ path: "statusline.sh", type: "blob", sha: SH_SHA },
		{ path: "statusline.ts", type: "blob", sha: tsSha },
	];
	return Promise.resolve(new Response(JSON.stringify({ tree })));
}

function run(fx: Fixture, fetchImpl: typeof fetch, nowMs = Date.now()) {
	return checkForUpdate({
		file: "statusline.ts",
		ownPath: fx.ownPath,
		cacheDir: fx.cacheDir,
		url: TREE_URL,
		nowMs,
		fetchImpl,
	});
}

test("gitBlobSha matches git", () => {
	assert.equal(gitBlobSha(Buffer.from("hello\n")), "ce013625030ba8dba906f756967f9e9ca394464a");
	// Multi-byte: the header must use the byte length, not the string length
	assert.equal(gitBlobSha(Buffer.from("󰚰\n")), "09ebc88cf6351459a137dd50824369d626f8e4d0");
});

test("parseTreeShas keeps valid entries", () => {
	const tsSha = "d".repeat(40);
	const body = {
		tree: [
			{ path: "statusline.ts", type: "blob", sha: tsSha },
			{ path: "statusline.sh", type: "blob", sha: "xyz" },
			{ path: "README.md", type: "blob", sha: "e".repeat(40) },
		],
	};
	assert.deepEqual(parseTreeShas(body), { "statusline.ts": tsSha });
	assert.deepEqual(parseTreeShas({ message: "API rate limit exceeded" }), {});
	assert.deepEqual(parseTreeShas(null), {});
});

test("parseUpdateCache round-trips and rejects garbage", () => {
	const shas = { "statusline.sh": SH_SHA, "statusline.ts": STALE_SHA };
	assert.deepEqual(parseUpdateCache(formatUpdateCache(shas)), shas);
	assert.deepEqual(parseUpdateCache("garbage"), {});
});

test("garbage stamp is due", () => {
	const now = 1_800_000_000_000;
	const nowS = now / 1_000;
	assert.equal(isUpdateCheckDue("soon", now), true);
	assert.equal(isUpdateCheckDue(undefined, now), true);
	assert.equal(isUpdateCheckDue(String(nowS - (INTERVAL_S - 1)), now), false);
	assert.equal(isUpdateCheckDue(`${nowS - (INTERVAL_S + 1)}\n`, now), true);
});

test("stale file reports update", async () => {
	const fx = await fixture();
	const fetcher = fakeFetch(() => treeResponse(STALE_SHA));
	assert.equal(await run(fx, fetcher.impl), true);
	assert.equal(fetcher.calls.length, 1);
	assert.match(await readFile(join(fx.cacheDir, "update-checked"), "utf8"), /^\d+\n$/);
	assert.deepEqual(parseUpdateCache(await readFile(join(fx.cacheDir, "update-master"), "utf8")), {
		"statusline.sh": SH_SHA,
		"statusline.ts": STALE_SHA,
	});
});

test("current file reports none", async () => {
	const fx = await fixture();
	assert.equal(await run(fx, fakeFetch(() => treeResponse(fx.ownSha)).impl), false);
});

test("uses fresh cache without fetching", async () => {
	const fx = await fixture();
	await seedCache(fx.cacheDir, STALE_SHA, Math.floor(Date.now() / 1_000));
	const fetcher = fakeFetch(() => Promise.reject(new Error("must not fetch")));
	assert.equal(await run(fx, fetcher.impl), true);
	assert.equal(fetcher.calls.length, 0);
});

test("error body keeps previous cache", async () => {
	const fx = await fixture();
	const nowS = Math.floor(Date.now() / 1_000);
	await seedCache(fx.cacheDir, STALE_SHA, nowS - INTERVAL_S - 1);
	const before = await readFile(join(fx.cacheDir, "update-master"), "utf8");
	const body = JSON.stringify({ message: "API rate limit exceeded" });
	const fetcher = fakeFetch(() => Promise.resolve(new Response(body, { status: 403 })));
	assert.equal(await run(fx, fetcher.impl), true);
	assert.equal(fetcher.calls.length, 1);
	assert.equal(await readFile(join(fx.cacheDir, "update-master"), "utf8"), before);
	const stamp = Number((await readFile(join(fx.cacheDir, "update-checked"), "utf8")).trim());
	assert.ok(stamp >= nowS, `stamp ${stamp} should be refreshed`);
});

test("fetch rejection reports none and does not throw", async () => {
	const fx = await fixture();
	assert.equal(await run(fx, fakeFetch(() => Promise.reject(new Error("offline"))).impl), false);
});

test("missing own file reports none", async () => {
	const fx = await fixture();
	await seedCache(fx.cacheDir, STALE_SHA, Math.floor(Date.now() / 1_000));
	await rm(fx.ownPath);
	assert.equal(await run(fx, fakeFetch(() => treeResponse(STALE_SHA)).impl), false);
});

test("unwritable cache dir reports none and does not throw", async () => {
	const fx = await fixture();
	const blocker = join(fx.dir, "blocker");
	await writeFile(blocker, "");
	const fetcher = fakeFetch(() => treeResponse(STALE_SHA));
	const result = await checkForUpdate({
		file: "statusline.ts",
		ownPath: fx.ownPath,
		cacheDir: join(blocker, "cache"),
		url: TREE_URL,
		nowMs: Date.now(),
		fetchImpl: fetcher.impl,
	});
	assert.equal(result, false);
	assert.equal(fetcher.calls.length, 0);
});

test("updateNoticeLine exact text", () => {
	assert.equal(
		updateNoticeLine("statusline.ts"),
		"\x1b[1;38;5;16;48;5;208m 󰚰 Update available — statusline.ts changed on master · git pull && ./install.sh \x1b[0m",
	);
});

// ---------- footer wiring: drives the real extension with minimal Pi stand-ins ----------

type FooterComponent = { render(width: number): string[]; dispose(): void };

async function withEnv<T>(env: Record<string, string | undefined>, body: () => Promise<T>): Promise<T> {
	const saved = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
	const apply = (values: Record<string, string | undefined>) => {
		for (const [key, value] of Object.entries(values)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	};
	apply(env);
	try {
		return await body();
	} finally {
		apply(saved);
	}
}

function mountFooter(cwd: string): FooterComponent {
	const handlers = new Map<string, (event: unknown, ctx: unknown) => void>();
	const pi = {
		on: (name: string, handler: (event: unknown, ctx: unknown) => void) => handlers.set(name, handler),
		exec: async () => ({ code: 1, stdout: "", stderr: "" }),
		getThinkingLevel: () => "off",
	};
	statuslineExtension(pi as never);
	let factory: ((tui: unknown, theme: unknown, footerData: unknown) => FooterComponent) | undefined;
	const ctx = {
		mode: "tui",
		cwd,
		model: undefined,
		ui: { setFooter: (value: typeof factory) => (factory = value) },
		sessionManager: { getEntries: () => [], getBranch: () => [], getHeader: () => undefined, getSessionName: () => undefined },
		getContextUsage: () => undefined,
		hasPendingMessages: () => false,
		isIdle: () => true,
	};
	handlers.get("session_start")?.({}, ctx);
	assert.ok(factory, "session_start should install a footer");
	return factory(
		{ requestRender: () => {} },
		{ fg: (_color: string, text: string) => text },
		{ onBranchChange: () => () => {}, getGitBranch: () => undefined, getExtensionStatuses: () => new Map() },
	);
}

async function renderAfterChecks(footer: FooterComponent, wantLines: number): Promise<string[]> {
	for (let attempt = 0; attempt < 50 && footer.render(200).length !== wantLines; attempt++) {
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
	return footer.render(200);
}

test("footer shows the notice as line 4", async () => {
	const fx = await fixture();
	// Fresh stamp + stale master entry for statusline.ts: no fetch, notice expected
	await seedCache(fx.cacheDir, STALE_SHA, Math.floor(Date.now() / 1_000));
	await withEnv({ STATUSLINE_UPDATE_CACHE: fx.cacheDir, STATUSLINE_UPDATE_CHECK: undefined }, async () => {
		const footer = mountFooter(fx.dir);
		try {
			const lines = await renderAfterChecks(footer, 4);
			assert.equal(lines.length, 4);
			assert.equal(lines[3], updateNoticeLine("statusline.ts"));
		} finally {
			footer.dispose();
		}
	});
});

test("footer hides the notice when disabled", async () => {
	const fx = await fixture();
	await seedCache(fx.cacheDir, STALE_SHA, Math.floor(Date.now() / 1_000));
	await withEnv({ STATUSLINE_UPDATE_CACHE: fx.cacheDir, STATUSLINE_UPDATE_CHECK: "0" }, async () => {
		const footer = mountFooter(fx.dir);
		try {
			await new Promise((resolve) => setTimeout(resolve, 200));
			assert.equal(footer.render(200).length, 3);
		} finally {
			footer.dispose();
		}
	});
});
