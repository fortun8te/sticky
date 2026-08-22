const DEFAULT_PORT = 53318;
const DEFAULT_TIMEOUT_MS = 10_000;
const MAX_TIMEOUT_MS = 120_000;
const DEFAULT_MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const DEFAULT_MAX_REQUEST_BYTES = 1024 * 1024;
const MAX_TEXT_LENGTH = 200_000;
const MAX_FILE_COUNT = 100;
const MAX_TOTAL_FILE_BYTES = 2 * 1024 * 1024 * 1024;

function readIntegerEnv(name: string, fallback: number, minimum: number, maximum: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}

export interface BridgeConfig {
  readonly baseUrl: URL;
  readonly controlToken: string;
  readonly requestTimeoutMs: number;
  readonly maxResponseBytes: number;
  readonly maxRequestBytes: number;
  readonly maxTextLength: number;
  readonly maxFileCount: number;
  readonly maxTotalFileBytes: number;
}

export function loadConfig(): BridgeConfig {
  const port = readIntegerEnv("STICKY_PORT", DEFAULT_PORT, 1, 65535);
  const timeoutMs = readIntegerEnv(
    "STICKY_TIMEOUT_MS",
    DEFAULT_TIMEOUT_MS,
    250,
    MAX_TIMEOUT_MS,
  );
  const maxResponseBytes = readIntegerEnv(
    "STICKY_MAX_RESPONSE_BYTES",
    DEFAULT_MAX_RESPONSE_BYTES,
    1024,
    64 * 1024 * 1024,
  );
  const controlToken = process.env.STICKY_CONTROL_TOKEN ?? "";
  if (!/^[a-f0-9]{64}$/i.test(controlToken)) {
    throw new Error("STICKY_CONTROL_TOKEN is missing; launch Sticky once, then use Sticky's registered MCP bridge");
  }

  return {
    baseUrl: new URL(`http://127.0.0.1:${port}/api/v1/control/`),
    controlToken,
    requestTimeoutMs: timeoutMs,
    maxResponseBytes,
    maxRequestBytes: DEFAULT_MAX_REQUEST_BYTES,
    maxTextLength: MAX_TEXT_LENGTH,
    maxFileCount: MAX_FILE_COUNT,
    maxTotalFileBytes: MAX_TOTAL_FILE_BYTES,
  };
}
