export interface UserTurn {
	text: string;
	role: "user";
}

export interface ClassificationInput {
	latest: string;
	previousUserTurns: string[];
	lastIntent?: "code" | "general";
}

const MAX_TURN_CHARS = 2_000;

export function buildClassificationInput(
	messages: readonly { role?: string; content?: unknown }[],
	lastIntent?: "code" | "general",
	includeConversationContext = true,
): ClassificationInput {
	const userTurns = messages
		.filter((message) => message.role === "user")
		.map((message) => ({ role: "user" as const, text: textContent(message.content).slice(-MAX_TURN_CHARS) }));
	const latest = userTurns.at(-1)?.text ?? "";
	return {
		latest: latest.slice(-MAX_TURN_CHARS),
		previousUserTurns: includeConversationContext ? userTurns.slice(-4, -1).map((turn) => turn.text) : [],
		...(includeConversationContext && lastIntent ? { lastIntent } : {}),
	};
}

function textContent(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((part): part is { type: "text"; text: string } =>
			typeof part === "object" && part !== null && (part as { type?: unknown }).type === "text" &&
			typeof (part as { text?: unknown }).text === "string")
		.map((part) => part.text)
		.join("\n")
}
