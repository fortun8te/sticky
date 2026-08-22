#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { loadConfig } from "./config.js";
import { StickyControlApi } from "./api.js";
import { StickyHttpClient, StickyApiError } from "./http.js";
import { InputValidationError, validateFiles, validateText } from "./validation.js";

const config = loadConfig();
const api = new StickyControlApi(new StickyHttpClient(config), config);
const server = new McpServer({ name: "sticky", version: "1.0.0" });

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
};

function jsonResult(value: unknown): ToolResult {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

function errorResult(error: unknown): ToolResult {
  if (error instanceof InputValidationError) {
    return { content: [{ type: "text", text: error.message }], isError: true };
  }
  if (error instanceof StickyApiError) {
    const suffix = error.details === undefined ? "" : ` ${JSON.stringify(error.details)}`;
    return { content: [{ type: "text", text: `${error.message}${suffix}` }], isError: true };
  }
  const message = error instanceof Error ? error.message : "Unexpected Sticky bridge failure";
  return { content: [{ type: "text", text: message }], isError: true };
}

server.tool(
  "sticky_peer_status",
  "Get the local Sticky identity and discovered LAN peers",
  {
    peerId: z.string().min(1).max(128).optional().describe("Return only this peer when provided"),
  },
  async ({ peerId }) => {
    try {
      const status = await api.getPeerStatus();
      const peers = peerId ? status.peers.filter((peer) => peer.id === peerId) : status.peers;
      if (peerId && peers.length === 0) return errorResult(new InputValidationError("Peer was not found"));
      return jsonResult({ ...status, peers });
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_send_files",
  "Ask the local Sticky app to send regular files to a paired peer",
  {
    paths: z.array(z.string().min(1).max(4096)).min(1).max(config.maxFileCount)
      .describe("Absolute paths of regular files to send"),
    peerId: z.string().min(1).max(128).optional().describe("Target peer; omit to use Sticky's selected peer"),
  },
  async ({ paths, peerId }) => {
    try {
      const files = await validateFiles(paths, config);
      const result = await api.send({ peerId, kind: "files", files });
      return jsonResult(result);
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_send_text",
  "Ask the local Sticky app to send UTF-8 text to a paired peer",
  {
    text: z.string().min(1).max(config.maxTextLength).describe("Plain UTF-8 text to send"),
    peerId: z.string().min(1).max(128).optional().describe("Target peer; omit to use Sticky's selected peer"),
  },
  async ({ text, peerId }) => {
    try {
      const safeText = validateText(text, config);
      const result = await api.send({ peerId, kind: "text", text: safeText });
      return jsonResult(result);
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_read_clipboard",
  "Read the separate Sticky clipboard and its recent entries",
  {},
  async () => {
    try {
      return jsonResult(await api.getClipboard());
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_write_clipboard",
  "Write plain UTF-8 text into the separate Sticky clipboard without changing the system clipboard",
  {
    text: z.string().min(1).max(config.maxTextLength).describe("Plain UTF-8 text to store"),
  },
  async ({ text }) => {
    try {
      return jsonResult(await api.writeClipboard(validateText(text, config)));
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_transfer_history",
  "List recent Sticky transfers and their states",
  {
    limit: z.number().int().min(1).max(100).default(20).describe("Maximum records to return"),
    peerId: z.string().min(1).max(128).optional().describe("Only transfers involving this peer"),
  },
  async ({ limit, peerId }) => {
    try {
      const allTransfers = await api.listTransfers();
      const transfers = allTransfers
        .filter((transfer) => !peerId || transfer.peerId === peerId)
        .slice(0, limit);
      return jsonResult({ transfers });
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_transfer_status",
  "Get one Sticky transfer by UUID",
  { transferId: z.string().uuid().describe("Transfer UUID") },
  async ({ transferId }) => {
    try {
      return jsonResult(await api.getTransfer(transferId));
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_cancel_transfer",
  "Cancel an active Sticky transfer by UUID",
  { transferId: z.string().uuid().describe("Transfer UUID") },
  async ({ transferId }) => {
    try {
      return jsonResult(await api.cancelTransfer(transferId));
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_list_errors",
  "List recent Sticky errors from the local app",
  { limit: z.number().int().min(1).max(100).default(20).describe("Maximum errors to return") },
  async ({ limit }) => {
    try {
      return jsonResult({ errors: (await api.listErrors()).slice(0, limit) });
    } catch (error) {
      return errorResult(error);
    }
  },
);

server.tool(
  "sticky_clear_errors",
  "Clear Sticky's user-visible error list",
  {},
  async () => {
    try {
      return jsonResult(await api.clearErrors());
    } catch (error) {
      return errorResult(error);
    }
  },
);

let shuttingDown = false;
async function shutdown(signal: NodeJS.Signals): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  console.error(`Sticky MCP server received ${signal}; shutting down`);
  await server.close();
  process.exitCode = 0;
}

process.once("SIGINT", () => void shutdown("SIGINT"));
process.once("SIGTERM", () => void shutdown("SIGTERM"));

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`Sticky MCP server listening on stdio (local API: ${config.baseUrl.origin})`);
