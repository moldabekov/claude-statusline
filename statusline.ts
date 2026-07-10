import { readFile, readdir, stat } from "node:fs/promises";
import { cpus, freemem, hostname, loadavg, release, totalmem } from "node:os";
import { basename, sep } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

type MeterColor = "success" | "warning" | "error";

type RateWindow = {
	label: string;
	usedPercent: number;
	resetAt?: number;
};

type CiState =
	| { kind: "none" }
	| {
			kind: "run";
			status: string;
			conclusion: string;
			updatedAt?: number;
	  };

type CheckCounts = {
	success: number;
	failure: number;
	pending: number;
};

type HealthResult = {
	ok: boolean;
	issues?: number;
	updatedAt: number;
};

type LocalHealthState = {
	tests?: HealthResult;
	lint?: HealthResult;
	types?: HealthResult;
};

type PullRequestState = {
	number: number;
	isDraft: boolean;
	reviewDecision: string;
	mergeable: string;
	url?: string;
	unresolvedThreads?: number;
	checks: CheckCounts;
	tests: CheckCounts;
	quality: CheckCounts;
};

type GitState = {
	isRepo: boolean;
	commitEpoch?: number;
	modified: number;
	staged: number;
	untracked: number;
	additions: number;
	deletions: number;
	ahead: number;
	behind: number;
	stash: number;
	headSha?: string;
	repoName?: string;
	worktree?: string;
	ci?: CiState;
	pr?: PullRequestState;
};

type ActiveToolState = {
	name: string;
	startedAt: number;
};

type SystemState = {
	battery?: number;
	goVersion?: string;
	goWorkspace?: boolean;
	node?: string;
	python?: string;
	rust?: string;
	zig?: string;
	java?: string;
	terraform?: string;
	container?: string;
	dockerContext?: string;
	kubeContext?: string;
	awsProfile?: string;
	awsRegion?: string;
	diskUsedPercent?: number;
	tmux?: string;
};

type ProjectRuntimes = {
	go: boolean;
	goWorkspace: boolean;
	node: boolean;
	python: boolean;
	rust: boolean;
	zig: boolean;
	java: boolean;
	terraform: boolean;
	docker: boolean;
	kubernetes: boolean;
	aws: boolean;
};

type UsageTotals = {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
};

const EMPTY_GIT_STATE: GitState = {
	isRepo: false,
	modified: 0,
	staged: 0,
	untracked: 0,
	additions: 0,
	deletions: 0,
	ahead: 0,
	behind: 0,
	stash: 0,
};

function clean(text: string): string {
	return text.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/ +/g, " ").trim();
}

function cleanStatus(text: string): string {
	return text.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

function finiteNumber(value: unknown): number | undefined {
	const parsed = typeof value === "number" ? value : Number.parseFloat(String(value ?? ""));
	return Number.isFinite(parsed) ? parsed : undefined;
}

function clamp(value: number, minimum: number, maximum: number): number {
	return Math.min(maximum, Math.max(minimum, value));
}

function meterColor(percent: number): MeterColor {
	if (percent >= 80) return "error";
	if (percent >= 60) return "warning";
	return "success";
}

function compactPath(path: string): string {
	const home = process.env.HOME || process.env.USERPROFILE;
	if (!home) return path;
	if (path === home) return "~";
	if (path.startsWith(`${home}${sep}`)) return `~${path.slice(home.length)}`;
	return path;
}

function formatNumber(value: number): string {
	if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
	if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
	return Math.round(value).toString();
}

function formatRate(value: number): string {
	if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M/m`;
	if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K/m`;
	return `${Math.round(value)}/m`;
}

function formatAge(seconds: number): string {
	const age = Math.max(0, Math.floor(seconds));
	if (age >= 86_400) return `${Math.floor(age / 86_400)}d`;
	if (age >= 3_600) return `${Math.floor(age / 3_600)}h`;
	if (age >= 60) return `${Math.floor(age / 60)}m`;
	return `${age}s`;
}

function formatDuration(seconds: number): string {
	const duration = Math.max(0, Math.floor(seconds));
	if (duration >= 3_600) return `${Math.floor(duration / 3_600)}h${Math.floor((duration % 3_600) / 60)}m`;
	if (duration >= 60) return `${Math.floor(duration / 60)}m`;
	return `${duration}s`;
}

function formatReset(resetAt: number, now = Date.now()): string {
	const remaining = Math.floor((resetAt - now) / 1_000);
	if (remaining <= 0) return "now";
	if (remaining >= 86_400) {
		const date = new Date(resetAt);
		const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
		return `${months[date.getMonth()]}${String(date.getDate()).padStart(2, "0")}`;
	}
	if (remaining >= 3_600) return `${Math.floor(remaining / 3_600)}h${Math.floor((remaining % 3_600) / 60)}m`;
	if (remaining >= 60) return `${Math.floor(remaining / 60)}m`;
	return `${remaining}s`;
}

function rateWindowLabel(minutes: number | undefined, fallback: "primary" | "secondary"): string {
	if (!minutes || minutes <= 0) return fallback === "primary" ? "5h" : "7d";
	if (minutes % 10_080 === 0) return `${minutes / 10_080 * 7}d`;
	if (minutes % 1_440 === 0) return `${minutes / 1_440}d`;
	if (minutes % 60 === 0) return `${minutes / 60}h`;
	return `${Math.round(minutes)}m`;
}

function parseResetAt(headers: Record<string, string>, prefix: string, now: number): number | undefined {
	const after = finiteNumber(headers[`${prefix}-reset-after-seconds`] ?? headers[`${prefix}-reset-after`]);
	if (after !== undefined) return now + Math.max(0, after) * 1_000;

	const raw = headers[`${prefix}-resets-at`] ?? headers[`${prefix}-reset-at`];
	if (!raw) return undefined;
	const numeric = finiteNumber(raw);
	if (numeric !== undefined) return numeric > 1_000_000_000_000 ? numeric : numeric * 1_000;
	const parsed = Date.parse(raw);
	return Number.isFinite(parsed) ? parsed : undefined;
}

function parseRateWindows(rawHeaders: Record<string, string>): RateWindow[] {
	const headers = Object.fromEntries(Object.entries(rawHeaders).map(([key, value]) => [key.toLowerCase(), value]));
	const now = Date.now();
	const windows: RateWindow[] = [];

	for (const name of ["primary", "secondary"] as const) {
		const prefix = `x-codex-${name}`;
		const usedPercent = finiteNumber(headers[`${prefix}-used-percent`]);
		if (usedPercent === undefined) continue;
		const minutes = finiteNumber(headers[`${prefix}-window-minutes`] ?? headers[`${prefix}-window-mins`]);
		windows.push({
			label: rateWindowLabel(minutes, name),
			usedPercent: clamp(usedPercent, 0, 100),
			resetAt: parseResetAt(headers, prefix, now),
		});
	}

	return windows;
}

function collectUsage(ctx: ExtensionContext): UsageTotals {
	const totals: UsageTotals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
	for (const entry of ctx.sessionManager.getEntries()) {
		if (entry.type !== "message" || entry.message.role !== "assistant") continue;
		const usage = entry.message.usage;
		totals.input += finiteNumber(usage.input) ?? 0;
		totals.output += finiteNumber(usage.output) ?? 0;
		totals.cacheRead += finiteNumber(usage.cacheRead) ?? 0;
		totals.cacheWrite += finiteNumber(usage.cacheWrite) ?? 0;
		totals.cost += finiteNumber(usage.cost?.total) ?? 0;
	}
	return totals;
}

function parseDirtyStatus(output: string): Pick<GitState, "modified" | "staged" | "untracked"> {
	let modified = 0;
	let staged = 0;
	let untracked = 0;
	for (const line of output.split("\n")) {
		if (line.length < 2) continue;
		if (line.startsWith("??")) {
			untracked++;
			continue;
		}
		if (line[1] === "M") modified++;
		if (/[MADRC]/.test(line[0] ?? "")) staged++;
	}
	return { modified, staged, untracked };
}

function parseNumstat(output: string): Pick<GitState, "additions" | "deletions"> {
	let additions = 0;
	let deletions = 0;
	for (const line of output.split("\n")) {
		const [added, deleted] = line.split("\t", 2);
		const addedCount = finiteNumber(added);
		const deletedCount = finiteNumber(deleted);
		if (addedCount !== undefined) additions += Math.max(0, addedCount);
		if (deletedCount !== undefined) deletions += Math.max(0, deletedCount);
	}
	return { additions, deletions };
}

type GitHubCheck = {
	name?: string;
	context?: string;
	workflowName?: string;
	status?: string;
	conclusion?: string;
	state?: string;
};

function summarizeChecks(checks: GitHubCheck[], matcher?: RegExp): CheckCounts {
	const counts: CheckCounts = { success: 0, failure: 0, pending: 0 };
	for (const check of checks) {
		const name = `${check.workflowName ?? ""} ${check.name ?? check.context ?? ""}`;
		if (matcher && !matcher.test(name)) continue;
		const outcome = (check.conclusion || check.state || "").toUpperCase();
		const status = (check.status || "").toUpperCase();
		if (["SUCCESS", "NEUTRAL", "SKIPPED"].includes(outcome)) {
			counts.success++;
		} else if (["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"].includes(outcome)) {
			counts.failure++;
		} else if (outcome === "PENDING" || status !== "COMPLETED") {
			counts.pending++;
		} else {
			counts.pending++;
		}
	}
	return counts;
}

function checkCount(counts: CheckCounts): number {
	return counts.success + counts.failure + counts.pending;
}

function commandHealthKinds(command: string): Array<keyof LocalHealthState> {
	const kinds: Array<keyof LocalHealthState> = [];
	if (
		/\b(pytest|jest|vitest|mocha|ava)\b|\bcargo\s+(?:test|nextest)\b|\bgo\s+test\b|\bdotnet\s+test\b|\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test(?::[\w-]+)?\b/i.test(
			command,
		)
	) {
		kinds.push("tests");
	}
	if (
		/\b(eslint|pylint|golangci-lint)\b|\bbiome\s+(?:check|lint)\b|\bruff\s+check\b|\bcargo\s+clippy\b|\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?lint(?::[\w-]+)?\b/i.test(
			command,
		)
	) {
		kinds.push("lint");
	}
	if (
		/\btsc\b|\b(mypy|pyright)\b|\bcargo\s+check\b|\bgo\s+vet\b|\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:typecheck|type-check|check:types)\b/i.test(
			command,
		)
	) {
		kinds.push("types");
	}
	return kinds;
}

function toolResultText(result: unknown): string {
	if (!result || typeof result !== "object") return "";
	const content = (result as { content?: unknown }).content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.map((item) =>
			item && typeof item === "object" && "text" in item ? String((item as { text?: unknown }).text ?? "") : "",
		)
		.join("\n");
}

function parseHealthIssues(output: string, kind: keyof LocalHealthState): number | undefined {
	if (kind === "tests") {
		const match = output.match(/(?:^|\s)(\d+)\s+(?:tests?\s+)?failed\b/i);
		return match ? Number(match[1]) : undefined;
	}
	if (kind === "lint") {
		const match = output.match(/(?:found\s+)?(\d+)\s+errors?\b/i);
		return match ? Number(match[1]) : undefined;
	}
	const typeScriptErrors = output.match(/\berror\s+TS\d+:/gi)?.length;
	if (typeScriptErrors) return typeScriptErrors;
	const match = output.match(/(?:found\s+)?(\d+)\s+errors?\b/i);
	return match ? Number(match[1]) : undefined;
}

function fitSegments(base: string, segments: string[], width: number): string {
	let line = truncateToWidth(base, width, "");
	for (const segment of segments) {
		if (visibleWidth(line) + visibleWidth(segment) <= width) line += segment;
	}
	return line;
}

function alignLeftRight(left: string, right: string, width: number): string {
	const fittedRight = truncateToWidth(right, Math.max(1, width), "");
	const rightWidth = visibleWidth(fittedRight);
	if (rightWidth >= width) return fittedRight;
	const fittedLeft = truncateToWidth(left, Math.max(0, width - rightWidth - 1), "");
	const gap = " ".repeat(Math.max(1, width - visibleWidth(fittedLeft) - rightWidth));
	return fittedLeft + gap + fittedRight;
}

async function fileExists(path: string): Promise<boolean> {
	try {
		await stat(path);
		return true;
	} catch {
		return false;
	}
}

function projectRoots(cwd: string, repoRoot?: string): string[] {
	return [...new Set([cwd, repoRoot].filter((path): path is string => Boolean(path)))];
}

async function readProjectFile(roots: string[], names: string[]): Promise<string | undefined> {
	for (const root of roots) {
		for (const name of names) {
			const content = await readTrimmed(`${root}${sep}${name}`);
			if (content) return content;
		}
	}
	return undefined;
}

async function detectProjectRuntimes(cwd: string, repoRoot?: string): Promise<ProjectRuntimes> {
	const roots = projectRoots(cwd, repoRoot);
	const entryLists = await Promise.all(
		roots.map(async (root) => {
			try {
				return await readdir(root);
			} catch {
				return [];
			}
		}),
	);
	const names = new Set(entryLists.flat().map((name) => name.toLowerCase()));
	const toolConfig =
		(await readProjectFile(roots, [".tool-versions", ".mise.toml", "mise.toml"]))?.toLowerCase() ?? "";
	const packageJson = (await readProjectFile(roots, ["package.json"]))?.toLowerCase() ?? "";
	const virtualEnv = process.env.VIRTUAL_ENV;
	const projectVirtualEnv = Boolean(
		virtualEnv && roots.some((root) => virtualEnv === root || virtualEnv.startsWith(`${root}${sep}`)),
	);

	const goWorkspace = names.has("go.work");
	const go =
		["go.mod", "go.sum", "go.work", "go.work.sum"].some((name) => names.has(name)) ||
		[...names].some((name) => name.endsWith(".go")) ||
		/\b(go|golang)\b/.test(toolConfig);
	const node =
		["package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", ".nvmrc", ".node-version"].some(
			(name) => names.has(name),
		) || /\b(node|nodejs|bun|deno)\b/.test(toolConfig);
	const python =
		["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "pipfile", "poetry.lock", "uv.lock", ".python-version", "tox.ini"].some(
			(name) => names.has(name),
		) ||
		[...names].some((name) => /^requirements[-.].*\.txt$/.test(name)) ||
		/\bpython\b/.test(toolConfig) ||
		projectVirtualEnv;
	const rust =
		["cargo.toml", "cargo.lock", "rust-toolchain", "rust-toolchain.toml"].some((name) => names.has(name)) ||
		[...names].some((name) => name.endsWith(".rs")) ||
		/\b(rust|rustup)\b/.test(toolConfig);
	const zig =
		["build.zig", "build.zig.zon", ".zig-version"].some((name) => names.has(name)) ||
		[...names].some((name) => name.endsWith(".zig")) ||
		/\bzig\b/.test(toolConfig);
	const java =
		["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew", ".java-version", ".sdkmanrc"].some(
			(name) => names.has(name),
		) ||
		[...names].some((name) => name.endsWith(".java")) ||
		/\b(java|jdk|temurin)\b/.test(toolConfig);
	const terraform =
		[".terraform.lock.hcl", "terragrunt.hcl"].some((name) => names.has(name)) ||
		[...names].some((name) => name.endsWith(".tf") || name.endsWith(".tfvars")) ||
		/\b(terraform|tofu)\b/.test(toolConfig);
	const docker = [...names].some(
		(name) =>
			/^dockerfile(?:\..+)?$/.test(name) ||
			/^(?:docker-)?compose(?:\.[\w-]+)?\.ya?ml$/.test(name) ||
			name === ".devcontainer",
	);
	const kubernetes =
		["k8s", "kubernetes", "helm", "charts", "chart.yaml", "kustomization.yaml", "kustomization.yml", "skaffold.yaml", "skaffold.yml", "helmfile.yaml", "tiltfile"].some(
			(name) => names.has(name),
		);
	const aws =
		["cdk.json", "samconfig.toml", "serverless.yml", "serverless.yaml", "sst.config.ts", "sst.config.js", "amplify", ".aws-sam"].some(
			(name) => names.has(name),
		) || /(?:@aws-sdk|aws-sdk|aws-cdk|\bsst\b|\bserverless\b)/.test(packageJson);

	return { go, goWorkspace, node, python, rust, zig, java, terraform, docker, kubernetes, aws };
}

async function detectContainer(): Promise<string | undefined> {
	if (process.env.container) return clean(process.env.container);
	if (await fileExists("/.dockerenv")) return "docker";
	if (await fileExists("/run/.containerenv")) return "podman";
	const cgroup = (await readTrimmed("/proc/1/cgroup"))?.toLowerCase() ?? "";
	if (cgroup.includes("kubepods")) return "kubernetes";
	if (cgroup.includes("docker")) return "docker";
	if (cgroup.includes("libpod") || cgroup.includes("podman")) return "podman";
	if (process.env.WSL_INTEROP || /microsoft|wsl/i.test(release())) return "WSL";
	return undefined;
}

async function readTrimmed(path: string): Promise<string | undefined> {
	try {
		return clean(await readFile(path, "utf8"));
	} catch {
		return undefined;
	}
}

export default function statuslineExtension(pi: ExtensionAPI) {
	let rateWindows: RateWindow[] = [];
	let rateProvider: string | undefined;
	let requestFooterRender: (() => void) | undefined;
	let localHealth: LocalHealthState = {};
	let agentStartedAt: number | undefined;
	const activeTools = new Map<string, ActiveToolState>();
	const bashCommands = new Map<string, string>();

	pi.on("agent_start", () => {
		agentStartedAt = Date.now();
		requestFooterRender?.();
	});

	pi.on("agent_settled", () => {
		agentStartedAt = undefined;
		activeTools.clear();
		requestFooterRender?.();
	});

	pi.on("tool_execution_start", (event) => {
		activeTools.set(event.toolCallId, { name: event.toolName, startedAt: Date.now() });
		requestFooterRender?.();
		if (event.toolName !== "bash") return;
		const command = event.args && typeof event.args.command === "string" ? event.args.command : undefined;
		if (command) bashCommands.set(event.toolCallId, command);
	});

	pi.on("tool_execution_end", (event) => {
		activeTools.delete(event.toolCallId);
		requestFooterRender?.();
		if (event.toolName !== "bash") return;
		const command = bashCommands.get(event.toolCallId);
		bashCommands.delete(event.toolCallId);
		if (!command) return;
		const kinds = commandHealthKinds(command);
		if (kinds.length === 0) return;
		const output = toolResultText(event.result);
		const updatedAt = Date.now();
		for (const kind of kinds) {
			localHealth = {
				...localHealth,
				[kind]: {
					ok: !event.isError,
					issues: event.isError ? parseHealthIssues(output, kind) : 0,
					updatedAt,
				},
			};
		}
		requestFooterRender?.();
	});

	pi.on("after_provider_response", (event, ctx) => {
		const parsed = parseRateWindows(event.headers);
		if (parsed.length === 0) return;
		rateWindows = parsed;
		rateProvider = ctx.model?.provider;
		requestFooterRender?.();
	});

	pi.on("model_select", () => requestFooterRender?.());
	pi.on("thinking_level_select", () => requestFooterRender?.());
	pi.on("message_end", () => requestFooterRender?.());
	pi.on("session_compact", () => requestFooterRender?.());
	pi.on("session_info_changed", () => requestFooterRender?.());
	pi.on("session_tree", () => requestFooterRender?.());

	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "tui") return;

		const cwd = ctx.cwd;
		const headerTimestamp = ctx.sessionManager.getHeader()?.timestamp;
		const parsedStart = headerTimestamp ? Date.parse(headerTimestamp) : Number.NaN;
		const sessionStartedAt = Number.isFinite(parsedStart) ? parsedStart : Date.now();

		ctx.ui.setFooter((tui, theme, footerData) => {
			let disposed = false;
			let gitState: GitState = { ...EMPTY_GIT_STATE };
			let systemState: SystemState = {};
			let gitRefreshRunning = false;
			let gitRefreshPending = false;
			let systemRefreshRunning = false;
			let lastGitRefresh = 0;
			let lastSystemRefresh = 0;
			let ciHeadSha: string | undefined;
			let ciLastFetch = 0;
			let ciRefreshRunning = false;
			const abortController = new AbortController();

			const localRequestRender = () => {
				if (!disposed) tui.requestRender();
			};
			requestFooterRender = localRequestRender;

			const run = async (command: string, args: string[], timeout = 4_000) => {
				try {
					return await pi.exec(command, args, {
						cwd,
						timeout,
						signal: abortController.signal,
					});
				} catch {
					return undefined;
				}
			};

			const runGit = (args: string[], timeout?: number) => run("git", ["-C", cwd, ...args], timeout);

			const refreshUnresolvedThreads = async (headSha: string, pr: PullRequestState) => {
				if (!pr.url) return;
				try {
					const url = new URL(pr.url);
					const [, owner, name] = url.pathname.split("/");
					if (!owner || !name) return;
					const query =
						"query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}";
					const result = await run(
						"gh",
						[
							"api",
							"graphql",
							"-f",
							`query=${query}`,
							"-f",
							`owner=${owner}`,
							"-f",
							`name=${name}`,
							"-F",
							`number=${pr.number}`,
						],
						6_000,
					);
					if (!result || result.code !== 0 || disposed || gitState.headSha !== headSha || gitState.pr?.number !== pr.number) {
						return;
					}
					const response = JSON.parse(result.stdout) as {
						data?: {
							repository?: {
								pullRequest?: { reviewThreads?: { nodes?: Array<{ isResolved?: boolean }> } };
							};
						};
					};
					const threads = response.data?.repository?.pullRequest?.reviewThreads?.nodes;
					if (!threads) return;
					gitState = {
						...gitState,
						pr: { ...gitState.pr!, unresolvedThreads: threads.filter((thread) => !thread.isResolved).length },
					};
					localRequestRender();
				} catch {
					// Review-thread data is optional and unavailable to some GitHub tokens.
				}
			};

			const refreshGitHub = async (headSha: string) => {
				const now = Date.now();
				if (ciRefreshRunning) return;
				if (ciHeadSha === headSha && now - ciLastFetch < 60_000) return;
				ciRefreshRunning = true;
				ciHeadSha = headSha;
				ciLastFetch = now;
				try {
					const [runResult, prResult] = await Promise.all([
						run(
							"gh",
							["run", "list", "--commit", headSha, "--limit", "1", "--json", "status,conclusion,updatedAt"],
							6_000,
						),
						run(
							"gh",
							[
								"pr",
								"view",
								"--json",
								"number,isDraft,reviewDecision,mergeable,statusCheckRollup,url",
							],
							6_000,
						),
					]);
					if (disposed || gitState.headSha !== headSha) return;

					let ci = gitState.ci;
					if (runResult?.code === 0) {
						const rows = JSON.parse(runResult.stdout) as Array<{
							status?: string;
							conclusion?: string;
							updatedAt?: string;
						}>;
						const row = rows[0];
						ci = row
							? {
									kind: "run",
									status: row.status ?? "",
									conclusion: row.conclusion ?? "",
									updatedAt: row.updatedAt ? Date.parse(row.updatedAt) : undefined,
							  }
							: { kind: "none" };
					}

					let pr = gitState.pr;
					if (prResult?.code === 0) {
						const row = JSON.parse(prResult.stdout) as {
							number: number;
							isDraft?: boolean;
							reviewDecision?: string;
							mergeable?: string;
							url?: string;
							statusCheckRollup?: GitHubCheck[];
						};
						const checks = Array.isArray(row.statusCheckRollup) ? row.statusCheckRollup : [];
						pr = {
							number: row.number,
							isDraft: Boolean(row.isDraft),
							reviewDecision: (row.reviewDecision ?? "").toUpperCase(),
							mergeable: (row.mergeable ?? "").toUpperCase(),
							url: row.url,
							checks: summarizeChecks(checks),
							tests: summarizeChecks(checks, /(?:^|[\s/_.-])(test|tests|unit|integration|e2e|spec|pytest|jest|vitest)(?:[\s/_.-]|$)/i),
							quality: summarizeChecks(checks, /(?:lint|eslint|biome|type[ -]?check|typescript|tsc|mypy|pyright|ruff|clippy|format|prettier)/i),
						};
					} else if (prResult) {
						pr = undefined;
					}

					gitState = { ...gitState, ci, pr };
					localRequestRender();
					if (pr) void refreshUnresolvedThreads(headSha, pr);
				} catch {
					// GitHub CLI, authentication, and JSON failures are intentionally silent.
				} finally {
					ciRefreshRunning = false;
				}
			};

			const refreshGit = async () => {
				const probe = await runGit(["rev-parse", "--is-inside-work-tree"]);
				if (!probe || probe.code !== 0 || clean(probe.stdout) !== "true") {
					if (!disposed) {
						gitState = { ...EMPTY_GIT_STATE };
						localRequestRender();
					}
					return;
				}

				const [commit, status, numstat, upstream, stashes, head, paths] = await Promise.all([
					runGit(["log", "-1", "--format=%ct"]),
					runGit(["status", "--porcelain=v1", "--untracked-files=all"], 8_000),
					runGit(["diff", "--numstat", "HEAD", "--"], 8_000),
					runGit(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]),
					runGit(["stash", "list"]),
					runGit(["rev-parse", "HEAD"]),
					runGit(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--show-toplevel"]),
				]);
				if (disposed) return;

				const dirty = parseDirtyStatus(status?.code === 0 ? status.stdout : "");
				const changedLines = parseNumstat(numstat?.code === 0 ? numstat.stdout : "");
				const aheadBehind = upstream?.code === 0 ? upstream.stdout.trim().split(/\s+/).map(Number) : [];
				const pathLines = paths?.code === 0 ? paths.stdout.split("\n").map(clean).filter(Boolean) : [];
				const gitDir = pathLines[0]?.replace(/[\\/]+$/, "");
				const commonDir = pathLines[1]?.replace(/[\\/]+$/, "");
				const topLevel = pathLines[2];
				const headSha = head?.code === 0 ? clean(head.stdout) : undefined;
				const sameHead = gitState.headSha === headSha;

				gitState = {
					isRepo: true,
					commitEpoch: commit?.code === 0 ? finiteNumber(commit.stdout) : undefined,
					...dirty,
					...changedLines,
					ahead: Number.isFinite(aheadBehind[0]) ? Math.max(0, aheadBehind[0]!) : 0,
					behind: Number.isFinite(aheadBehind[1]) ? Math.max(0, aheadBehind[1]!) : 0,
					stash:
						stashes?.code === 0
							? stashes.stdout.split("\n").map(clean).filter(Boolean).length
							: 0,
					headSha,
					repoName: topLevel ? basename(topLevel) : basename(cwd),
					worktree: gitDir && commonDir && gitDir !== commonDir && topLevel ? basename(topLevel) : undefined,
					ci: sameHead ? gitState.ci : undefined,
					pr: sameHead ? gitState.pr : undefined,
				};
				localRequestRender();
				if (headSha) void refreshGitHub(headSha);
			};

			const scheduleGitRefresh = () => {
				if (disposed) return;
				if (gitRefreshRunning) {
					gitRefreshPending = true;
					return;
				}
				gitRefreshRunning = true;
				lastGitRefresh = Date.now();
				void refreshGit().finally(() => {
					gitRefreshRunning = false;
					if (gitRefreshPending && !disposed) {
						gitRefreshPending = false;
						scheduleGitRefresh();
					}
				});
			};

			const refreshSystem = async () => {
				const rootResult = await runGit(["rev-parse", "--show-toplevel"], 2_500);
				const repoRoot = rootResult?.code === 0 ? clean(rootResult.stdout) || undefined : undefined;
				const roots = projectRoots(cwd, repoRoot);
				const runtimes = await detectProjectRuntimes(cwd, repoRoot);
				const batteryPromise = (async () => {
					for (const battery of ["BAT0", "BAT1"]) {
						const capacity = finiteNumber(await readTrimmed(`/sys/class/power_supply/${battery}/capacity`));
						if (capacity !== undefined) return clamp(Math.round(capacity), 0, 100);
					}
					return undefined;
				})();
				const goPromise = runtimes.go
					? (async () => {
							const configured = await readProjectFile(roots, ["go.work", "go.mod"]);
							const configuredVersion =
								configured?.match(/\btoolchain\s+go([0-9][\w.-]*)/i)?.[1] ??
								configured?.match(/\bgo\s+([0-9][\w.-]*)/i)?.[1];
							if (configuredVersion) return configuredVersion;
							const result = await run("go", ["version"], 2_500);
							if (result?.code !== 0) return undefined;
							return clean(result.stdout).match(/\bgo version go([^\s]+)/i)?.[1];
						})()
					: Promise.resolve(undefined);
				const nodePromise = runtimes.node
					? (async () => {
							const configured = await readProjectFile(roots, [".nvmrc", ".node-version"]);
							return clean(configured || process.version).replace(/^v/i, "");
						})()
					: Promise.resolve(undefined);
				const pythonPromise = runtimes.python
					? (async () => {
							const configured = await readProjectFile(roots, [".python-version"]);
							if (configured) return configured.replace(/^python-?/i, "");
							const virtualEnv = process.env.VIRTUAL_ENV;
							const command = virtualEnv ? `${virtualEnv}${sep}bin${sep}python` : "python3";
							const result = await run(command, ["--version"], 2_500);
							if (result?.code !== 0) return virtualEnv ? basename(virtualEnv) : undefined;
							const versionText = clean(result.stdout || result.stderr).replace(/^Python\s+/i, "");
							if (!versionText) return virtualEnv ? basename(virtualEnv) : undefined;
							return virtualEnv ? `${versionText}@${basename(virtualEnv)}` : versionText;
						})()
					: Promise.resolve(undefined);
				const rustPromise = runtimes.rust
					? (async () => {
							const configured = await readProjectFile(roots, ["rust-toolchain.toml", "rust-toolchain"]);
							const channel =
								configured?.match(/\bchannel\s*=\s*["']([^"']+)["']/i)?.[1] ??
								(configured && !configured.includes("=") ? configured.split(/\s+/)[0] : undefined);
							if (channel) return channel;
							const result = await run("rustc", ["--version"], 2_500);
							return result?.code === 0 ? clean(result.stdout).match(/^rustc\s+([^\s]+)/i)?.[1] : undefined;
						})()
					: Promise.resolve(undefined);
				const zigPromise = runtimes.zig
					? run("zig", ["version"], 2_500).then((result) =>
							result?.code === 0 ? clean(result.stdout) || undefined : undefined,
						)
					: Promise.resolve(undefined);
				const javaPromise = runtimes.java
					? run("java", ["-version"], 2_500).then((result) => {
							if (result?.code !== 0) return undefined;
							const text = clean(`${result.stdout} ${result.stderr}`);
							return text.match(/\bversion\s+["']([^"']+)["']/i)?.[1] ?? text.match(/\b(?:openjdk|java)\s+([^\s]+)/i)?.[1];
						})
					: Promise.resolve(undefined);
				const terraformPromise = runtimes.terraform
					? run("terraform", ["version"], 2_500).then((result) =>
							result?.code === 0 ? clean(result.stdout).match(/\bTerraform\s+v?([^\s]+)/i)?.[1] : undefined,
						)
					: Promise.resolve(undefined);
				const containerPromise = detectContainer();
				const dockerPromise = runtimes.docker
					? run("docker", ["context", "show"], 2_500).then((result) =>
							result?.code === 0 ? clean(result.stdout) || undefined : undefined,
						)
					: Promise.resolve(undefined);
				const kubePromise = runtimes.kubernetes
					? run("kubectl", ["config", "current-context"], 2_500).then((result) =>
							result?.code === 0 ? clean(result.stdout) || undefined : undefined,
						)
					: Promise.resolve(undefined);
				const awsRegionPromise = !runtimes.aws
					? Promise.resolve(undefined)
					: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION
						? Promise.resolve(clean(process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || ""))
						: run(
								"aws",
								["configure", "get", "region", ...(process.env.AWS_PROFILE ? ["--profile", process.env.AWS_PROFILE] : [])],
								2_500,
							).then((result) => (result?.code === 0 ? clean(result.stdout) || undefined : undefined));
				const diskPromise = run("df", ["-Pk", cwd], 2_500).then((result) => {
					if (result?.code !== 0) return undefined;
					const line = result.stdout.trim().split("\n").at(-1);
					const match = line?.match(/(\d+)%/);
					return match ? clamp(Number(match[1]), 0, 100) : undefined;
				});
				const tmuxPromise = process.env.TMUX
					? run("tmux", ["display-message", "-p", "#S"]).then((result) =>
							result?.code === 0 ? clean(result.stdout) || undefined : undefined,
						)
					: Promise.resolve(undefined);
				const [
					battery,
					goVersion,
					node,
					python,
					rust,
					zig,
					java,
					terraform,
					container,
					dockerContext,
					kubeContext,
					awsRegion,
					diskUsedPercent,
					tmux,
				] = await Promise.all([
					batteryPromise,
					goPromise,
					nodePromise,
					pythonPromise,
					rustPromise,
					zigPromise,
					javaPromise,
					terraformPromise,
					containerPromise,
					dockerPromise,
					kubePromise,
					awsRegionPromise,
					diskPromise,
					tmuxPromise,
				]);
				if (disposed) return;
				systemState = {
					battery,
					goVersion,
					goWorkspace: runtimes.goWorkspace,
					node,
					python,
					rust,
					zig,
					java,
					terraform,
					container,
					dockerContext: container && container !== "WSL" ? undefined : dockerContext,
					kubeContext,
					awsProfile: runtimes.aws && process.env.AWS_PROFILE ? clean(process.env.AWS_PROFILE) : undefined,
					awsRegion,
					diskUsedPercent,
					tmux,
				};
				localRequestRender();
			};

			const scheduleSystemRefresh = () => {
				if (disposed || systemRefreshRunning) return;
				systemRefreshRunning = true;
				lastSystemRefresh = Date.now();
				void refreshSystem().finally(() => {
					systemRefreshRunning = false;
				});
			};

			const unsubscribeBranch = footerData.onBranchChange(() => {
				scheduleGitRefresh();
				localRequestRender();
			});

			scheduleGitRefresh();
			scheduleSystemRefresh();
			const timer = setInterval(() => {
				if (disposed) return;
				localRequestRender();
				const now = Date.now();
				if (now - lastGitRefresh >= 10_000) scheduleGitRefresh();
				if (now - lastSystemRefresh >= 60_000) scheduleSystemRefresh();
			}, 1_000);

			return {
				invalidate() {},
				render(width: number): string[] {
					const now = Date.now();
					const terminalWidth = Math.max(1, width);
					const usage = collectUsage(ctx);
					const context = ctx.getContextUsage();
					const rawPercent = context?.percent;
					const contextPercent =
						typeof rawPercent === "number" && Number.isFinite(rawPercent)
							? Math.floor(clamp(rawPercent, 0, 100))
							: undefined;
					const contextTokens = finiteNumber(context?.tokens);
					const contextWindow = finiteNumber(context?.contextWindow);
					const compactionCount = ctx.sessionManager
						.getBranch()
						.reduce((count, entry) => count + (entry.type === "compaction" ? 1 : 0), 0);
					const currentModel = ctx.model;
					const thinking = currentModel?.reasoning ? pi.getThinkingLevel() : "off";

					const user = clean(process.env.USER || process.env.LOGNAME || "unknown");
					const host = clean(process.env.HOSTNAME || hostname());
					const shortHost = host.split(".")[0] || host;
					const fullPath = clean(compactPath(cwd));
					const projectPath = clean(gitState.repoName || basename(cwd) || fullPath);
					const displayedPath = terminalWidth >= 140 ? fullPath : projectPath;
					const identity =
						terminalWidth >= 90
							? `${theme.fg("accent", "[")}${theme.fg("accent", `${user}@${host}`)}${theme.fg("accent", "]")}`
							: terminalWidth >= 65
								? theme.fg("accent", `${user}@${shortHost}`)
								: "";
					let line1Base = `💻${identity ? ` ${identity}` : ""} ▸ ${theme.fg("warning", displayedPath)}`;
					const sessionName = clean(ctx.sessionManager.getSessionName() || "");
					if (sessionName) {
						const displayedSessionName = truncateToWidth(sessionName, terminalWidth < 110 ? 14 : 28, "…");
						line1Base += ` ${theme.fg("muted", `[${displayedSessionName}]`)}`;
					}

					const footerBranch = footerData.getGitBranch();
					const branch =
						footerBranch === "detached" && gitState.headSha ? gitState.headSha.slice(0, 7) : footerBranch;
					if (branch) {
						const cleanBranch = clean(branch);
						const displayedBranch = terminalWidth < 110 ? truncateToWidth(cleanBranch, 16, "…") : cleanBranch;
						line1Base += ` ⎇ ${theme.fg("accent", displayedBranch)}`;
					}

					const renderCheckCounts = (label: string, counts: CheckCounts): string => {
						let output = label;
						if (counts.success > 0) output += ` ${theme.fg("success", `${counts.success}✓`)}`;
						if (counts.failure > 0) output += ` ${theme.fg("error", `${counts.failure}✗`)}`;
						if (counts.pending > 0) output += ` ${theme.fg("warning", `${counts.pending}…`)}`;
						return ` | ${output}`;
					};

					const line1Segments: string[] = [];
					if (gitState.pr) {
						const pr = gitState.pr;
						let label = `PR #${pr.number}`;
						let color: MeterColor | "accent" = "accent";
						if (pr.isDraft) {
							label += " draft";
							color = "warning";
						} else if (pr.mergeable === "CONFLICTING") {
							label += " conflict";
							color = "error";
						} else if (pr.reviewDecision === "APPROVED") {
							label += " ✓";
							color = "success";
						} else if (pr.reviewDecision === "CHANGES_REQUESTED") {
							label += " ✗";
							color = "error";
						} else if (pr.reviewDecision === "REVIEW_REQUIRED") {
							label += " ○";
							color = "warning";
						}
						if ((pr.unresolvedThreads ?? 0) > 0) label += ` 💬${pr.unresolvedThreads}`;
						line1Segments.push(` | ${theme.fg(color, label)}`);
						if (checkCount(pr.checks) > 0) line1Segments.push(renderCheckCounts("CI", pr.checks));
						if (checkCount(pr.tests) > 0) line1Segments.push(renderCheckCounts("T", pr.tests));
						if (checkCount(pr.quality) > 0) line1Segments.push(renderCheckCounts("Q", pr.quality));
					} else if (gitState.ci?.kind === "none") {
						line1Segments.push(" | CI ○");
					} else if (gitState.ci?.kind === "run") {
						const ciAge =
							gitState.ci.updatedAt && Number.isFinite(gitState.ci.updatedAt)
								? ` ${formatAge((now - gitState.ci.updatedAt) / 1_000)}`
								: "";
						if (gitState.ci.conclusion === "success") {
							line1Segments.push(` | CI ${theme.fg("success", `✓${ciAge}`)}`);
						} else if (["failure", "cancelled", "timed_out", "startup_failure"].includes(gitState.ci.conclusion)) {
							line1Segments.push(` | CI ${theme.fg("error", `✗${ciAge}`)}`);
						} else if (["in_progress", "queued", "waiting", "requested", "pending"].includes(gitState.ci.status)) {
							line1Segments.push(` | CI ${theme.fg("warning", `⋯${ciAge}`)}`);
						}
					}

					const renderLocalHealth = (label: string, result: HealthResult): string => {
						if (result.ok) return ` | ${theme.fg("success", `${label} ✓`)}`;
						const failures = result.issues && result.issues > 0 ? `${result.issues}` : "";
						return ` | ${theme.fg("error", `${label} ${failures}✗`)}`;
					};
					if (localHealth.tests) line1Segments.push(renderLocalHealth("test", localHealth.tests));
					if (localHealth.lint) line1Segments.push(renderLocalHealth("lint", localHealth.lint));
					if (localHealth.types) line1Segments.push(renderLocalHealth("types", localHealth.types));

					if (gitState.additions > 0 || gitState.deletions > 0) {
						line1Segments.push(
							` | Δ${theme.fg("success", `+${formatNumber(gitState.additions)}`)}${theme.fg("error", `−${formatNumber(gitState.deletions)}`)}`,
						);
					}
					const dirty: string[] = [];
					if (gitState.modified > 0) dirty.push(`●${gitState.modified}`);
					if (gitState.staged > 0) dirty.push(`+${gitState.staged}`);
					if (gitState.untracked > 0) dirty.push(`?${gitState.untracked}`);
					if (dirty.length > 0) line1Segments.push(` | ${dirty.join(" ")}`);
					const divergence: string[] = [];
					if (gitState.ahead > 0) divergence.push(`↑${gitState.ahead}`);
					if (gitState.behind > 0) divergence.push(`↓${gitState.behind}`);
					if (divergence.length > 0) line1Segments.push(` | ${divergence.join(" ")}`);
					if (gitState.commitEpoch !== undefined) {
						line1Segments.push(` ⏳ ${formatAge(Date.now() / 1_000 - gitState.commitEpoch)}`);
					}
					if (gitState.stash > 0) line1Segments.push(` | ≡${gitState.stash}`);
					if (gitState.worktree) line1Segments.push(` | ${clean(gitState.worktree)}`);

					const activeTool = [...activeTools.values()].at(-1);
					const queued = ctx.hasPendingMessages();
					let line1Right: string;
					if (activeTool) {
						const operation = truncateToWidth(clean(activeTool.name.replaceAll("_", " ")), 14, "…");
						const parallel = activeTools.size > 1 ? ` +${activeTools.size - 1}` : "";
						const elapsed = formatDuration((now - activeTool.startedAt) / 1_000);
						line1Right = theme.fg("accent", `⟳ ${operation}${parallel} ${elapsed}${queued ? " ⇥" : ""}`);
					} else if (!ctx.isIdle()) {
						const elapsed = formatDuration((now - (agentStartedAt ?? now)) / 1_000);
						line1Right = theme.fg("accent", `⟳ thinking ${elapsed}${queued ? " ⇥" : ""}`);
					} else if (queued) {
						line1Right = theme.fg("warning", "⇥ queued");
					} else {
						line1Right = theme.fg("dim", "○ idle");
					}
					const line1LeftWidth = Math.max(1, terminalWidth - visibleWidth(line1Right) - 1);
					const line1Left = fitSegments(line1Base, line1Segments, line1LeftWidth);
					const line1 = alignLeftRight(line1Left, line1Right, terminalWidth);

					const filled = contextPercent === undefined ? 0 : Math.floor(contextPercent / 10);
					const bar = `${"█".repeat(filled)}${"░".repeat(10 - filled)}`;
					const meter = `[${bar}] ${contextPercent === undefined ? "?" : `${contextPercent}%`}`;
					let line2 = `⚡ ${
						contextPercent === undefined
							? theme.fg("muted", meter)
							: theme.fg(meterColor(contextPercent), meter)
					}`;
					if (contextTokens !== undefined && contextWindow !== undefined && contextWindow > 0) {
						const remaining = Math.max(0, contextWindow - contextTokens);
						const compactions = compactionCount > 0 ? ` · ↻${compactionCount}` : "";
						const detail = `CTX ${formatNumber(contextTokens)}/${formatNumber(contextWindow)} · ${formatNumber(remaining)} left${compactions}`;
						line2 += ` | ${theme.fg(contextPercent === undefined ? "dim" : meterColor(contextPercent), detail)}`;
					}

					if (rateWindows.length > 0 && (!rateProvider || rateProvider === currentModel?.provider)) {
						const renderedLimits = rateWindows.map((window) => {
							const percent = Math.floor(window.usedPercent);
							const reset = window.resetAt ? ` ↻${formatReset(window.resetAt, now)}` : "";
							return theme.fg(meterColor(percent), `${window.label}: ${percent}%${reset}`);
						});
						line2 += ` | ⏱ ${renderedLimits.join(" / ")}`;
					}
					if (usage.cost > 0) line2 += ` | $${usage.cost.toFixed(2)}`;

					const durationSeconds = Math.max(0, (now - sessionStartedAt) / 1_000);
					const billedTokens = usage.input + usage.output;
					if (durationSeconds > 0 && billedTokens > 0) {
						const tokensPerMinute = billedTokens / (durationSeconds / 60);
						line2 += ` | 🔥 ${theme.fg(meterColor(tokensPerMinute >= 10_000 ? 100 : tokensPerMinute >= 3_000 ? 60 : 0), formatRate(tokensPerMinute))}`;
					}
					const modelName = clean(currentModel?.name || currentModel?.id || "no-model");
					const effort = thinking !== "off" ? ` (${thinking})` : "";
					line2 += ` | ✦ ${modelName}${effort}`;

					const date = new Date(now);
					const line3Base = `🕐 ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
					const line3Segments: string[] = [];
					if (systemState.goVersion) {
						line3Segments.push(` | Go ${clean(systemState.goVersion)}${systemState.goWorkspace ? " work" : ""}`);
					}
					if (systemState.node) {
						const nodeVersion = systemState.node.split(".").slice(0, 2).join(".");
						line3Segments.push(` | ⬡ node${clean(nodeVersion)}`);
					}
					if (systemState.python) line3Segments.push(` | 🐍 ${clean(systemState.python)}`);
					if (systemState.rust) line3Segments.push(` | 🦀 ${clean(systemState.rust)}`);
					if (systemState.zig) line3Segments.push(` | Zig ${clean(systemState.zig)}`);
					if (systemState.java) line3Segments.push(` | ☕ ${clean(systemState.java)}`);
					if (systemState.terraform) line3Segments.push(` | TF ${clean(systemState.terraform)}`);
					if (systemState.container) line3Segments.push(` | 📦 ${clean(systemState.container)}`);
					if (systemState.dockerContext) line3Segments.push(` | 🐳 ${clean(systemState.dockerContext)}`);
					if (systemState.kubeContext) {
						const kubeParts = clean(systemState.kubeContext).split(/[/:]/).filter(Boolean);
						const kubeContext = kubeParts.at(-1) || systemState.kubeContext;
						line3Segments.push(` | ☸ ${kubeContext}`);
					}
					if (systemState.awsProfile || systemState.awsRegion) {
						line3Segments.push(` | ☁ ${[systemState.awsProfile, systemState.awsRegion].filter(Boolean).join("@")}`);
					}

					const coreCount = Math.max(1, cpus().length);
					const cpuPressure = clamp(loadavg()[0] / coreCount * 100, 0, 999);
					const memoryPressure = totalmem() > 0 ? clamp((1 - freemem() / totalmem()) * 100, 0, 100) : 0;
					if (cpuPressure >= 80) {
						line3Segments.push(` | ${theme.fg(cpuPressure >= 100 ? "error" : "warning", `CPU ${Math.round(cpuPressure)}%`)}`);
					}
					if (memoryPressure >= 80) {
						line3Segments.push(` | ${theme.fg(memoryPressure >= 95 ? "error" : "warning", `RAM ${Math.round(memoryPressure)}%`)}`);
					}
					if ((systemState.diskUsedPercent ?? 0) >= 85) {
						line3Segments.push(
							` | ${theme.fg(systemState.diskUsedPercent! >= 95 ? "error" : "warning", `DISK ${systemState.diskUsedPercent}%`)}`,
						);
					}

					if (systemState.battery !== undefined) line3Segments.push(` | 🔋 ${systemState.battery}%`);
					if (durationSeconds >= 1) line3Segments.push(` | ⧗ ${formatDuration(durationSeconds)}`);
					const cacheTotal = usage.cacheRead + usage.cacheWrite;
					if (cacheTotal > 0) line3Segments.push(` | ❄ ${Math.round(usage.cacheRead * 100 / cacheTotal)}%`);
					if (usage.input > 0 || usage.output > 0) {
						line3Segments.push(` | ⇅ ${formatNumber(usage.input)} / ${formatNumber(usage.output)}`);
					}
					if (systemState.tmux) line3Segments.push(` | ${theme.fg("accent", `▦ ${clean(systemState.tmux)}`)}`);
					if (process.env.SSH_CONNECTION || process.env.SSH_CLIENT || process.env.SSH_TTY) {
						line3Segments.push(` | ${theme.fg("accent", "⇋ SSH")}`);
					}
					const line3 = fitSegments(line3Base, line3Segments, terminalWidth);

					const lines = [line1, line2, line3].map((line) => truncateToWidth(line, terminalWidth, ""));
					const statuses = Array.from(footerData.getExtensionStatuses().entries())
						.sort(([left], [right]) => left.localeCompare(right))
						.map(([, text]) => cleanStatus(text))
						.filter(Boolean);
					if (statuses.length > 0) lines.push(truncateToWidth(statuses.join(" "), terminalWidth, ""));
					return lines;
				},
				dispose() {
					disposed = true;
					clearInterval(timer);
					abortController.abort();
					unsubscribeBranch();
					if (requestFooterRender === localRequestRender) requestFooterRender = undefined;
				},
			};
		});
	});
}
