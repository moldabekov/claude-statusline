// Tests for the Pi statusline battery segment. Run via: bash tests/run.sh
import assert from "node:assert/strict";
import { test } from "node:test";
import { batteryColor, batteryIcon, isPluggedStatus, parsePmsetBattery } from "../statusline.ts";

test("batteryIcon fills by level in 10% steps", () => {
	assert.equal(batteryIcon(100, false), "\u{F0079}"); // battery (full)
	assert.equal(batteryIcon(75, false), "\u{F0081}"); // battery_80
	assert.equal(batteryIcon(35, false), "\u{F007D}"); // battery_40
	assert.equal(batteryIcon(3, false), "\u{F007A}"); // battery_10 (lowest icon)
	assert.equal(batteryIcon(0, false), "\u{F007A}");
});

test("batteryIcon uses charging icons when plugged in", () => {
	assert.equal(batteryIcon(100, true), "\u{F0085}"); // charging_100
	assert.equal(batteryIcon(15, true), "\u{F0086}"); // charging_20
	assert.equal(batteryIcon(35, true), "\u{F0088}"); // charging_40
	assert.equal(batteryIcon(3, true), "\u{F089C}"); // charging_10
});

test("batteryColor: green above 40, yellow 21-40, red at 20 or below", () => {
	assert.equal(batteryColor(41), "success");
	assert.equal(batteryColor(40), "warning");
	assert.equal(batteryColor(21), "warning");
	assert.equal(batteryColor(20), "error");
	assert.equal(batteryColor(0), "error");
});

test("isPluggedStatus reads Linux sysfs status", () => {
	assert.equal(isPluggedStatus("Charging"), true);
	assert.equal(isPluggedStatus("Full"), true);
	assert.equal(isPluggedStatus("Not charging"), true);
	assert.equal(isPluggedStatus("Discharging"), false);
	assert.equal(isPluggedStatus("Unknown"), false);
	assert.equal(isPluggedStatus(undefined), false);
});

test("parsePmsetBattery reads percent and power source", () => {
	const onAc = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=38600803)\t100%; charged; 0:00 remaining present: true\n";
	const onBattery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=38600803)\t42%; discharging; 3:10 remaining present: true\n";
	assert.deepEqual(parsePmsetBattery(onAc), { percent: 100, plugged: true });
	assert.deepEqual(parsePmsetBattery(onBattery), { percent: 42, plugged: false });
	assert.equal(parsePmsetBattery("Now drawing from 'AC Power'\n"), undefined); // desktop Mac
});
