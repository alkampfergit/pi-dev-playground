export type GuidanceClass = "steer" | "follow-up" | "next-turn";
export type GuidanceStatus = "queued" | "delivered" | "settled" | "cancelled";

export interface GuidanceItem {
	id: string;
	class: GuidanceClass;
	bytes: number;
	digest: string;
	status: GuidanceStatus;
}

export interface HeldCheckpoint {
	id: string;
	release: () => void;
	cancel: () => void;
}

export const MAX_TEXT_BYTES = 1024;
export const MAX_OUTSTANDING = 8;

export function utf8Bytes(text: string): number {
	return new TextEncoder().encode(text).byteLength;
}

export function validateText(text: string): { text: string; bytes: number } {
	const normalized = text.trim();
	if (!normalized) throw new Error("payload must not be empty");
	const bytes = utf8Bytes(normalized);
	if (bytes > MAX_TEXT_BYTES) throw new Error(`payload exceeds ${MAX_TEXT_BYTES} UTF-8 bytes`);
	return { text: normalized, bytes };
}

export class GuidanceState {
	readonly items = new Map<string, GuidanceItem>();
	held?: HeldCheckpoint;
	settledEvents = 0;

	add(item: Omit<GuidanceItem, "status">): GuidanceItem {
		if (this.outstanding() >= MAX_OUTSTANDING) throw new Error("guidance capacity reached");
		if (this.items.has(item.id)) throw new Error("duplicate opaque id");
		const created: GuidanceItem = { ...item, status: "queued" };
		this.items.set(created.id, created);
		return created;
	}

	deliver(id: string): boolean {
		const item = this.items.get(id);
		if (!item || item.status !== "queued") return false;
		item.status = "delivered";
		return true;
	}

	settle(): void {
		this.settledEvents++;
		for (const item of this.items.values()) {
			if (item.status === "delivered") item.status = "settled";
		}
	}

	cancelAll(): void {
		for (const item of this.items.values()) {
			if (item.status === "queued" || item.status === "delivered") item.status = "cancelled";
		}
		this.cancelCheckpoint();
	}

	outstanding(): number {
		return [...this.items.values()].filter((item) => item.status === "queued" || item.status === "delivered").length;
	}

	hold(checkpoint: HeldCheckpoint): void {
		if (this.held) throw new Error("a checkpoint is already held");
		this.held = checkpoint;
	}

	releaseCheckpoint(id: string): boolean {
		if (!this.held || this.held.id !== id) return false;
		const current = this.held;
		this.held = undefined;
		current.release();
		return true;
	}

	cancelCheckpoint(): boolean {
		if (!this.held) return false;
		const current = this.held;
		this.held = undefined;
		current.cancel();
		return true;
	}

	counts(): Record<string, number> {
		const result: Record<string, number> = {};
		for (const item of this.items.values()) {
			const key = `${item.class}:${item.status}`;
			result[key] = (result[key] ?? 0) + 1;
		}
		return result;
	}
}
