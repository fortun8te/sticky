import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import type { BridgeConfig } from "./config.js";
import type {
  ClipboardEntry,
  ClipboardSnapshot,
  LocalDeviceInfo,
  SendResponse,
  StickyDevice,
  StickyError,
  TransferRecord,
} from "./types.js";

export class InputValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InputValidationError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new InputValidationError(`${field} must be a non-empty string`);
  }
  return value;
}

function timestamp(value: unknown, field: string): string {
  if (typeof value !== "string" && typeof value !== "number") {
    throw new InputValidationError(`${field} must be an ISO string or epoch milliseconds`);
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new InputValidationError(`${field} is not a valid time`);
  return date.toISOString();
}

function parsePlatform(value: unknown): StickyDevice["platform"] {
  if (value !== "mac" && value !== "win") {
    throw new InputValidationError("platform must be either mac or win");
  }
  return value;
}

export function validateLocalDevice(value: unknown): LocalDeviceInfo {
  if (!isRecord(value)) throw new InputValidationError("local device must be an object");
  return {
    id: requiredString(value.id, "local.id"),
    name: requiredString(value.name, "local.name"),
    platform: parsePlatform(value.platform),
    ver: requiredString(value.ver, "local.ver"),
  };
}

export function validatePeer(value: unknown): StickyDevice {
  if (!isRecord(value)) throw new InputValidationError("peer must be an object");
  const port = typeof value.port === "number" && Number.isInteger(value.port)
    && value.port >= 1 && value.port <= 65535 ? value.port : undefined;
  return {
    id: requiredString(value.id, "peer.id"),
    name: requiredString(value.name, "peer.name"),
    platform: parsePlatform(value.platform),
    ver: requiredString(value.ver, "peer.ver"),
    host: optionalString(value.host),
    port,
    lastSeen: value.lastSeen === undefined ? undefined : timestamp(value.lastSeen, "peer.lastSeen"),
  };
}

export function validatePeers(value: unknown): StickyDevice[] {
  if (!Array.isArray(value)) throw new InputValidationError("peers must be an array");
  return value.map(validatePeer);
}

const TRANSFER_STATES = new Set([
  "queued", "preparing", "awaiting_acceptance", "sending", "completed", "failed", "cancelled",
]);

export function validateTransfer(value: unknown): TransferRecord {
  if (!isRecord(value)) throw new InputValidationError("transfer must be an object");
  const state = requiredString(value.state, "transfer.state");
  if (!TRANSFER_STATES.has(state)) throw new InputValidationError("transfer.state is unsupported");
  const kind = value.kind === "files" || value.kind === "text" ? value.kind : undefined;
  const direction = value.direction === "send" || value.direction === "receive" ? value.direction : undefined;
  if (!kind || !direction) throw new InputValidationError("transfer kind or direction is unsupported");

  const files = Array.isArray(value.files) ? value.files.map((item): { id?: string; path: string; name: string; size?: number; sha256?: string } => {
    if (!isRecord(item)) throw new InputValidationError("transfer file must be an object");
    const size = typeof item.size === "number" && Number.isSafeInteger(item.size) && item.size >= 0
      ? item.size : undefined;
    return {
      id: optionalString(item.id),
      path: requiredString(item.path, "transfer.file.path"),
      name: requiredString(item.name, "transfer.file.name"),
      size,
      sha256: optionalChecksum(item.sha256),
    };
  }) : undefined;

  const bytesTransferred = typeof value.bytesTransferred === "number"
    && Number.isSafeInteger(value.bytesTransferred) && value.bytesTransferred >= 0
    ? value.bytesTransferred : undefined;
  const totalBytes = typeof value.totalBytes === "number"
    && Number.isSafeInteger(value.totalBytes) && value.totalBytes >= 0
    ? value.totalBytes : undefined;

  return {
    id: requiredString(value.id, "transfer.id"),
    kind,
    direction,
    state: state as TransferRecord["state"],
    peerId: optionalString(value.peerId),
    peerName: optionalString(value.peerName),
    files,
    textPreview: optionalString(value.textPreview),
    bytesTransferred,
    totalBytes,
    error: optionalString(value.error),
    createdAt: timestamp(value.createdAt, "transfer.createdAt"),
    updatedAt: timestamp(value.updatedAt, "transfer.updatedAt"),
    completedAt: value.completedAt === undefined ? undefined : timestamp(value.completedAt, "transfer.completedAt"),
  };
}

function optionalChecksum(value: unknown): string | undefined {
  const checksum = optionalString(value);
  if (checksum && !/^[0-9a-f]{64}$/i.test(checksum)) {
    throw new InputValidationError("checksum must be a SHA-256 hex string");
  }
  return checksum;
}

export function validateTransfers(value: unknown): TransferRecord[] {
  if (!Array.isArray(value)) throw new InputValidationError("transfers must be an array");
  return value.map(validateTransfer);
}

export function validateClipboardEntry(value: unknown): ClipboardEntry {
  if (!isRecord(value)) throw new InputValidationError("clipboard entry must be an object");
  return {
    id: requiredString(value.id, "clipboard.id"),
    text: typeof value.text === "string" ? value.text : "",
    createdAt: timestamp(value.createdAt, "clipboard.createdAt"),
    senderName: optionalString(value.senderName),
  };
}

export function validateClipboardSnapshot(value: unknown): ClipboardSnapshot {
  if (!isRecord(value)) throw new InputValidationError("clipboard snapshot must be an object");
  const history = Array.isArray(value.history) ? value.history.map(validateClipboardEntry) : [];
  return {
    current: value.current == null ? null : validateClipboardEntry(value.current),
    history,
  };
}

export function validateErrors(value: unknown): StickyError[] {
  if (!Array.isArray(value)) throw new InputValidationError("errors must be an array");
  return value.map((item): StickyError => {
    if (!isRecord(item)) throw new InputValidationError("error must be an object");
    return {
      id: requiredString(item.id, "error.id"),
      message: requiredString(item.message, "error.message"),
      transferId: optionalString(item.transferId),
      createdAt: timestamp(item.createdAt, "error.createdAt"),
    };
  });
}

export function validateSendResponse(value: unknown): SendResponse {
  if (!isRecord(value)) throw new InputValidationError("send response must be an object");
  const transferId = optionalString(value.transferId) ?? optionalString(value.id);
  if (!transferId) throw new InputValidationError("send response has no transferId");
  return { transferId };
}

export function validateClearedCount(value: unknown): number {
  if (!isRecord(value)) throw new InputValidationError("clear response must be an object");
  const count = optionalString(value.cleared) ?? value.cleared;
  const numeric = typeof count === "number" ? count : Number(count);
  if (!Number.isSafeInteger(numeric) || numeric < 0) {
    throw new InputValidationError("clear response count is invalid");
  }
  return numeric;
}

export function validateTransferId(value: string): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new InputValidationError("transferId must be a UUID");
  }
  return value;
}

export function validateText(text: string, config: BridgeConfig): string {
  if (text.length === 0) throw new InputValidationError("text cannot be empty");
  if (text.includes("\0")) throw new InputValidationError("text cannot contain NUL bytes");
  if (/[\u0001-\u0008\u000B\u000C\u000E-\u001F]/.test(text)) {
    throw new InputValidationError("text must be plain UTF-8 without binary control characters");
  }
  if (Buffer.byteLength(text, "utf8") > config.maxTextLength * 4) {
    throw new InputValidationError("text is too large");
  }
  if (text.length > config.maxTextLength) throw new InputValidationError("text is too long");
  return text;
}

async function inspectFile(filePath: string, index: number, config: BridgeConfig): Promise<{ path: string; name: string; size: number }> {
  if (filePath.length === 0 || filePath.includes("\0")) {
    throw new InputValidationError(`paths[${index}] is invalid`);
  }
  if (!path.isAbsolute(filePath)) throw new InputValidationError(`paths[${index}] must be absolute`);

  const resolvedPath = path.resolve(filePath);
  let stats;
  try {
    stats = await stat(resolvedPath);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    throw new InputValidationError(code === "ENOENT" ? `paths[${index}] does not exist` : `paths[${index}] could not be inspected`);
  }
  if (!stats.isFile()) throw new InputValidationError(`paths[${index}] must be a regular file`);
  if (stats.size > config.maxTotalFileBytes) throw new InputValidationError(`paths[${index}] exceeds the per-file size limit`);
  return { path: resolvedPath, name: path.basename(resolvedPath), size: stats.size };
}

export async function validateFiles(paths: string[], config: BridgeConfig): Promise<Array<{ path: string; name: string; size: number }>> {
  if (paths.length === 0) throw new InputValidationError("at least one file is required");
  if (paths.length > config.maxFileCount) throw new InputValidationError(`at most ${config.maxFileCount} files are allowed`);
  const files = await Promise.all(paths.map((filePath, index) => inspectFile(filePath, index, config)));
  const totalBytes = files.reduce((total, file) => total + file.size, 0);
  if (totalBytes > config.maxTotalFileBytes) throw new InputValidationError("total file size exceeds the limit");
  return files;
}

export { createReadStream };
