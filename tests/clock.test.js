import assert from "node:assert/strict";
import test from "node:test";
import { formatTime } from "../source/clock.js";

test("formatTime zero-pads single-digit local time components", () => {
  assert.equal(formatTime(new Date(2026, 0, 1, 9, 5, 3)), "09:05:03");
});

test("formatTime uses 24-hour time at midnight, noon, and the end of the day", () => {
  assert.equal(formatTime(new Date(2026, 0, 1, 0, 0, 0)), "00:00:00");
  assert.equal(formatTime(new Date(2026, 0, 1, 12, 0, 0)), "12:00:00");
  assert.equal(formatTime(new Date(2026, 0, 1, 23, 59, 59)), "23:59:59");
});

test("formatTime reflects the next day after midnight rollover", () => {
  const date = new Date(2026, 0, 1, 23, 59, 59);
  date.setSeconds(date.getSeconds() + 1);
  assert.equal(formatTime(date), "00:00:00");
});
