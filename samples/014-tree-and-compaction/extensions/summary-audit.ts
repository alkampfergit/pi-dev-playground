import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type AuditRecord = {
  sequence: number;
  event: string;
  [key: string]: unknown;
};

const FIXTURE = process.env.PI_SUMMARY_AUDIT_FIXTURE === "1";

function shortId(id: string | null | undefined): string {
  return id ? id.slice(0, 6).toLowerCase() : "";
}

function optionalBoolean(value: boolean | undefined): boolean {
  return value === true;
}

function reasonOf(value: string): "manual" | "threshold" | "overflow" | "unknown" {
  return value === "manual" || value === "threshold" || value === "overflow" ? value : "unknown";
}

export default function summaryAudit(pi: ExtensionAPI) {
  let sequence = 0;
  let records: AuditRecord[] = [];

  const record = (event: string, fields: Record<string, unknown>) => {
    records.push({ sequence: sequence++, event, ...fields });
  };

  pi.on("session_start", () => {
    sequence = 0;
    records = [];
  });

  pi.on("session_before_tree", async (event) => {
    const preparation = event.preparation;
    record("session_before_tree", {
      targetIdPrefix: shortId(preparation.targetId),
      oldLeafIdPrefix: shortId(preparation.oldLeafId),
      commonAncestorIdPrefix: shortId(preparation.commonAncestorId),
      entriesToSummarize: preparation.entriesToSummarize.length,
      userWantsSummary: preparation.userWantsSummary === true,
      hasCustomInstructions: typeof preparation.customInstructions === "string",
      replaceInstructions: optionalBoolean(preparation.replaceInstructions),
      hasLabel: typeof preparation.label === "string",
      aborted: event.signal.aborted,
    });

    if (FIXTURE && preparation.userWantsSummary && !event.signal.aborted) {
      return {
        summary: {
          summary: "SUMMARY-AUDIT BRANCH V1",
          details: { schemaVersion: 1, fixture: "branch" },
        },
      };
    }
  });

  pi.on("session_tree", (event) => {
    record("session_tree", {
      newLeafIdPrefix: shortId(event.newLeafId),
      oldLeafIdPrefix: shortId(event.oldLeafId),
      hasSummaryEntry: event.summaryEntry !== undefined,
      summaryEntryIdPrefix: shortId(event.summaryEntry?.id),
      summaryFromIdPrefix: shortId(event.summaryEntry?.fromId),
      fromExtension: optionalBoolean(event.fromExtension),
    });
  });

  pi.on("session_before_compact", async (event) => {
    const preparation = event.preparation;
    const reason = reasonOf(event.reason);
    record("session_before_compact", {
      firstKeptEntryIdPrefix: shortId(preparation.firstKeptEntryId),
      tokensBefore: preparation.tokensBefore,
      isSplitTurn: preparation.isSplitTurn === true,
      messagesToSummarize: preparation.messagesToSummarize.length,
      turnPrefixMessages: preparation.turnPrefixMessages.length,
      hasPreviousSummary: preparation.previousSummary !== undefined,
      branchEntries: event.branchEntries.length,
      hasCustomInstructions: typeof event.customInstructions === "string",
      reason,
      willRetry: optionalBoolean(event.willRetry),
      aborted: event.signal.aborted,
    });

    if (FIXTURE && !event.signal.aborted) {
      return {
        compaction: {
          summary: "SUMMARY-AUDIT COMPACTION V1",
          firstKeptEntryId: preparation.firstKeptEntryId,
          tokensBefore: preparation.tokensBefore,
          details: { schemaVersion: 1, fixture: "compaction" },
        },
      };
    }
  });

  pi.on("session_compact", (event) => {
    record("session_compact", {
      compactionEntryIdPrefix: shortId(event.compactionEntry.id),
      firstKeptEntryIdPrefix: shortId(event.compactionEntry.firstKeptEntryId),
      tokensBefore: event.compactionEntry.tokensBefore,
      fromExtension: optionalBoolean(event.fromExtension),
      reason: reasonOf(event.reason),
      willRetry: optionalBoolean(event.willRetry),
    });
  });

  pi.registerCommand("summary-audit", {
    description: "Inspect or drive the sample's safe session audit",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      const [command, ...rest] = trimmed ? trimmed.split(/\s+/) : ["status"];

      if (command === "navigate") {
        if (rest.length !== 2 || !/^[0-9a-fA-F]{8}$/.test(rest[0]) || !/^(summary|plain)$/.test(rest[1])) {
          throw new Error("Usage: /summary-audit navigate <8-hex-entry-id> <summary|plain>");
        }
        const result = await ctx.navigateTree(rest[0].toLowerCase(), { summarize: rest[1] === "summary" });
        if (result.cancelled) throw new Error("Tree navigation was cancelled");
        return;
      }

      if (command === "checkpoint" && rest.length === 0) {
        pi.appendEntry("summary-audit-checkpoint", { schemaVersion: 1, records });
        if (ctx.hasUI) ctx.ui.notify(`summary-audit checkpoint records=${records.length}`, "info");
        return;
      }

      if (command === "status" && rest.length === 0) {
        if (ctx.hasUI) {
          const beforeTree = records.filter((item) => item.event === "session_before_tree").length;
          const tree = records.filter((item) => item.event === "session_tree").length;
          const beforeCompact = records.filter((item) => item.event === "session_before_compact").length;
          const compact = records.filter((item) => item.event === "session_compact").length;
          ctx.ui.notify(`summary-audit records=${records.length} tree=${beforeTree}/${tree} compact=${beforeCompact}/${compact}`, "info");
        }
        return;
      }

      throw new Error("Usage: /summary-audit status | checkpoint | navigate <8-hex-entry-id> <summary|plain>");
    },
  });
}
