// Mounts the real Pi footer with minimal stand-ins for the Pi API, for tests.
import assert from "node:assert/strict";
import statuslineExtension from "../statusline.ts";

export type FooterComponent = { render(width: number): string[]; dispose(): void };

export async function withEnv<T>(env: Record<string, string | undefined>, body: () => Promise<T>): Promise<T> {
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

export function mountFooter(cwd: string): FooterComponent {
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
