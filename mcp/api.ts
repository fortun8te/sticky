import type { StickyHttpClient } from "./http.js";
import type { BridgeConfig } from "./config.js";
import {
  validateClearedCount,
  validateClipboardSnapshot,
  validateErrors,
  validateLocalDevice,
  validatePeers,
  validateSendResponse,
  validateTransfer,
  validateTransferId,
  validateTransfers,
} from "./validation.js";
import type {
  ClearErrorsResponse,
  ClipboardSnapshot,
  PeerStatusSnapshot,
  SendRequest,
  SendResponse,
  StickyError,
  TransferRecord,
} from "./types.js";

export class StickyControlApi {
  constructor(private readonly client: StickyHttpClient, private readonly config: BridgeConfig) {}

 async getPeerStatus(): Promise<PeerStatusSnapshot> {
    const [local, peers] = await Promise.all([
      this.client.requestJson<unknown>({ method: "GET", endpoint: "/status" }),
      this.client.requestJson<unknown>({ method: "GET", endpoint: "/peers" }),
    ]);
    return { local: validateLocalDevice(local), peers: validatePeers(peers) };
  }

  async send(request: SendRequest): Promise<SendResponse> {
    const response = await this.client.requestJson<unknown>({
      method: "POST",
      endpoint: "/send",
      body: request,
    });
    return validateSendResponse(response);
  }

  async listTransfers(): Promise<TransferRecord[]> {
    const transfers = await this.client.requestJson<unknown>({
      method: "GET",
      endpoint: "/transfers",
    });
    return validateTransfers(transfers).sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  async getTransfer(transferId: string): Promise<TransferRecord> {
    const safeId = validateTransferId(transferId);
    const transfer = await this.client.requestJson<unknown>({
      method: "GET",
      endpoint: `/transfers/${safeId}`,
    });
    return validateTransfer(transfer);
  }

  async cancelTransfer(transferId: string): Promise<TransferRecord> {
    const safeId = validateTransferId(transferId);
    const transfer = await this.client.requestJson<unknown>({
      method: "POST",
      endpoint: `/transfers/${safeId}/cancel`,
    });
    return validateTransfer(transfer);
  }

  async getClipboard(): Promise<ClipboardSnapshot> {
    const clipboard = await this.client.requestJson<unknown>({
      method: "GET",
      endpoint: "/clipboard",
    });
    return validateClipboardSnapshot(clipboard);
  }

  async writeClipboard(text: string): Promise<ClipboardSnapshot> {
    const clipboard = await this.client.requestJson<unknown>({
      method: "PUT",
      endpoint: "/clipboard",
      body: { text },
    });
    return validateClipboardSnapshot(clipboard);
  }

  async listErrors(): Promise<StickyError[]> {
    const errors = await this.client.requestJson<unknown>({ method: "GET", endpoint: "/errors" });
    return validateErrors(errors);
  }

  async clearErrors(): Promise<ClearErrorsResponse> {
    const response = await this.client.requestJson<unknown>({
      method: "DELETE",
      endpoint: "/errors",
    });
    return { cleared: validateClearedCount(response) };
  }
}
