import type { BridgeConfig } from "./config.js";

export class StickyApiError extends Error {
  readonly status?: number;
  readonly details?: unknown;

  constructor(message: string, status?: number, details?: unknown) {
    super(message);
    this.name = "StickyApiError";
    this.status = status;
    this.details = details;
  }
}

interface RequestOptions {
  method: "GET" | "POST" | "PUT" | "DELETE";
  endpoint: string;
  body?: unknown;
  signal?: AbortSignal;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorDetails(value: unknown): unknown {
  if (!isRecord(value)) return undefined;
  const { error, message, details } = value;
  if (typeof error === "string") return { error, details };
  if (typeof message === "string") return { message, details };
  return undefined;
}

export class StickyHttpClient {
  constructor(private readonly config: BridgeConfig) {}

  async requestJson<T>(options: RequestOptions): Promise<T> {
    const url = new URL(options.endpoint.replace(/^\//, ""), this.config.baseUrl);
    const timeout = AbortSignal.timeout(this.config.requestTimeoutMs);
    const signals = [timeout, options.signal].filter((signal): signal is AbortSignal => !!signal);
    const abortController = new AbortController();
    const abort = (): void => abortController.abort();
    signals.forEach((signal) => signal.addEventListener("abort", abort, { once: true }));

    let response: Response;
    try {
      const serializedBody = options.body === undefined ? undefined : JSON.stringify(options.body);
      if (serializedBody !== undefined && Buffer.byteLength(serializedBody, "utf8") > this.config.maxRequestBytes) {
        throw new StickyApiError("Sticky API request exceeds the configured size limit");
      }
      response = await fetch(url, {
        method: options.method,
        headers: {
          "x-sticky-control-token": this.config.controlToken,
          ...(options.body === undefined ? {} : { "content-type": "application/json" }),
        },
        body: serializedBody,
        signal: abortController.signal,
        redirect: "error",
      });
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown fetch failure";
      throw new StickyApiError(timeout.aborted ? `Sticky API timed out after ${this.config.requestTimeoutMs}ms` : `Sticky API request failed: ${reason}`);
    } finally {
      signals.forEach((signal) => signal.removeEventListener("abort", abort));
    }

    const declaredLength = Number(response.headers.get("content-length") ?? "");
    if (Number.isSafeInteger(declaredLength) && declaredLength > this.config.maxResponseBytes) {
      await response.body?.cancel();
      throw new StickyApiError("Sticky API response exceeds the configured size limit", response.status);
    }

    const rawBody = await response.text();
    const bodyBytes = Buffer.byteLength(rawBody, "utf8");
    if (bodyBytes > this.config.maxResponseBytes) {
      throw new StickyApiError("Sticky API response exceeds the configured size limit", response.status);
    }

    let parsedBody: unknown = undefined;
    if (rawBody.length > 0) {
      try {
        parsedBody = JSON.parse(rawBody) as unknown;
      } catch {
        if (response.ok) throw new StickyApiError("Sticky API returned invalid JSON", response.status);
        parsedBody = { message: rawBody.slice(0, 2_000) };
      }
    }

    if (!response.ok) {
      const details = errorDetails(parsedBody);
      throw new StickyApiError(`Sticky API returned ${response.status}`, response.status, details);
    }

    return parsedBody as T;
  }
}
