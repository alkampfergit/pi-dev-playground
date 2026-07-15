import assert from "node:assert/strict";
import { GuidanceState, MAX_OUTSTANDING, utf8Bytes, validateText } from "../lib/guidance-state.ts";

assert.equal(validateText("  hello  ").text, "hello");
assert.equal(utf8Bytes("😀"), 4);
assert.throws(() => validateText(" \n "), /empty/);
assert.equal(validateText("é".repeat(512)).bytes, 1024);
assert.throws(() => validateText("é".repeat(513)), /UTF-8/);

const state = new GuidanceState();
state.add({ id: "opaque-1", class: "steer", bytes: 3, digest: "abc" });
assert.equal(state.items.get("opaque-1")?.status, "queued");
assert.equal(state.deliver("opaque-1"), true);
assert.equal(state.deliver("opaque-1"), false);
state.settle();
assert.equal(state.items.get("opaque-1")?.status, "settled");
assert.equal(state.settledEvents, 1);

const nextTurn = new GuidanceState();
nextTurn.add({ id: "next-1", class: "next-turn", bytes: 4, digest: "next" });
nextTurn.settle();
assert.equal(nextTurn.items.get("next-1")?.status, "queued");
assert.equal(nextTurn.deliver("next-1"), true);
nextTurn.settle();
assert.equal(nextTurn.items.get("next-1")?.status, "settled");

const capacity = new GuidanceState();
for (let i = 0; i < MAX_OUTSTANDING; i++) capacity.add({ id: `id-${i}`, class: "follow-up", bytes: 1, digest: `${i}` });
assert.throws(() => capacity.add({ id: "extra", class: "steer", bytes: 1, digest: "x" }), /capacity/);

assert.equal(capacity.deliver("id-0"), true);

let released = 0;
let cancelled = 0;
capacity.hold({ id: "checkpoint-1", release: () => released++, cancel: () => cancelled++ });
assert.throws(() => capacity.hold({ id: "checkpoint-2", release() {}, cancel() {} }), /already held/);
assert.equal(capacity.releaseCheckpoint("wrong"), false);
assert.equal(capacity.releaseCheckpoint("checkpoint-1"), true);
assert.equal(capacity.releaseCheckpoint("checkpoint-1"), false);
assert.equal(released, 1);

capacity.hold({ id: "checkpoint-3", release() {}, cancel: () => cancelled++ });
capacity.cancelAll();
assert.equal(cancelled, 1);
assert.equal(capacity.held, undefined);
assert.ok([...capacity.items.values()].every((item) => item.status === "cancelled"));

console.log("PASS: guidance state transitions, capacity, UTF-8 bounds, abort, and cleanup");
