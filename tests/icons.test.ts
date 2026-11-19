// Tests for the Pi statusline Nerd Font icons. Run via: bash tests/run.sh
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { clockIcon, osIcon, parseOsReleaseId } from "../statusline.ts";
import { mountFooter, withEnv } from "./footer-harness.ts";

const ROOT = join(import.meta.dirname, "..");
const BRAIN = "\u{F09D1}";

test("osIcon picks the nf-linux distro logo", () => {
	assert.equal(osIcon("linux", "fedora"), "\u{F30A}");
	assert.equal(osIcon("linux", "ubuntu"), "\u{F31B}");
	assert.equal(osIcon("linux", "opensuse-tumbleweed"), "\u{F314}");
	assert.equal(osIcon("linux", "raspbian"), "\u{F315}");
	assert.equal(osIcon("freebsd", "freebsd"), "\u{F30C}");
});

test("osIcon falls back by platform, then to Tux", () => {
	assert.equal(osIcon("darwin", undefined), "\u{F302}"); // nf-linux-apple
	assert.equal(osIcon("freebsd", undefined), "\u{F30C}");
	assert.equal(osIcon("win32", undefined), "\u{F17A}"); // nf-fa-windows
	assert.equal(osIcon("linux", undefined), "\u{F31A}"); // nf-linux-tux
	assert.equal(osIcon("linux", "plan9"), "\u{F31A}");
});

test("parseOsReleaseId reads plain and quoted IDs", () => {
	assert.equal(parseOsReleaseId('NAME="Fedora Linux"\nID=fedora\nID_LIKE=rhel\n'), "fedora");
	assert.equal(parseOsReleaseId('ID="opensuse-tumbleweed"\n'), "opensuse-tumbleweed");
	assert.equal(parseOsReleaseId("ID='alpine'\n"), "alpine");
	assert.equal(parseOsReleaseId("NAME=x\n"), undefined);
});

test("clockIcon shows the hour on an outline clock", () => {
	assert.equal(clockIcon(1), "\u{F144B}"); // clock_time_one_outline
	assert.equal(clockIcon(4), "\u{F144E}");
	assert.equal(clockIcon(12), "\u{F1456}"); // clock_time_twelve_outline
	assert.equal(clockIcon(0), "\u{F1456}"); // midnight
	assert.equal(clockIcon(13), "\u{F144B}");
	assert.equal(clockIcon(23), "\u{F1455}");
});

test("sources no longer use the replaced emoji and text labels", () => {
	const replaced = ["💻", "⚡", "🕐", "⏳", "🔥", "🐍", "🦀", "☕", "📦", "🐳", "💬", "⎇", "⏱", "✦", "❄", "⇅", "⧗", "☁", "▦", "⇋", "⬡", "☸", "🔋"];
	for (const file of ["statusline.sh", "statusline.ts"]) {
		const source = readFileSync(join(ROOT, file), "utf8");
		const left = replaced.filter((emoji) => source.includes(emoji));
		assert.deepEqual(left, [], `${file} still contains ${left.join(" ")}`);
	}
	const ts = readFileSync(join(ROOT, "statusline.ts"), "utf8");
	for (const label of ["` | Go ", "` | Zig ", "` | TF "]) assert.ok(!ts.includes(label), `statusline.ts still has ${label}`);
});

test("footer lines start with the host logo, brain, and hour clock", async () => {
	const dir = await mkdtemp(join(tmpdir(), "statusline-icons-"));
	let release = "";
	try {
		release = readFileSync("/etc/os-release", "utf8");
	} catch {
		// macOS and others have no os-release
	}
	await withEnv({ STATUSLINE_UPDATE_CHECK: "0" }, async () => {
		const footer = mountFooter(dir);
		try {
			const [line1, line2, line3] = footer.render(200);
			assert.ok(line1.startsWith(`${osIcon(process.platform, parseOsReleaseId(release))} `), `line 1: ${line1}`);
			assert.ok(line2.startsWith(`${BRAIN} `), `line 2: ${line2}`);
			assert.ok(line3.startsWith(`${clockIcon(new Date().getHours())} `), `line 3: ${line3}`);
		} finally {
			footer.dispose();
			await rm(dir, { recursive: true, force: true });
		}
	});
});
