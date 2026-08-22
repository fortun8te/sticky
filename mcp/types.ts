export type StickyPlatform = "mac" | "win";

export type TransferState =
  | "queued"
  | "preparing"
  | "awaiting_acceptance"
  | "sending"
  | "completed"
  | "failed"
  | "cancelled";

export type TransferKind = "files" | "text";
export type TransferDirection = "send" | "receive";

export interface StickyDevice {
  id: string;
  name: string;
  platform: StickyPlatform;
  ver: string;
  host?: string;
  port?: number;
  lastSeen?: string;
}

export interface LocalDeviceInfo {
  id: string;
  name: string;
  platform: StickyPlatform;
  ver: string;
}

export interface OutgoingFileMetadata {
  path: string;
  name: string;
  size: number;
  sha256?: string;
}

export interface SendRequest {
  peerId?: string;
  kind: TransferKind;
  files?: OutgoingFileMetadata[];
  text?: string;
}

export interface SendResponse {
  transferId: string;
}

export interface TransferRecord {
  id: string;
  kind: TransferKind;
  direction: TransferDirection;
  state: TransferState;
  peerId?: string;
  peerName?: string;
  files?: Array<{ id?: string; path: string; name: string; size?: number; sha256?: string }>;
  textPreview?: string;
  bytesTransferred?: number;
  totalBytes?: number;
  error?: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
}

export interface ClipboardEntry {
  id: string;
  text: string;
  createdAt: string;
  senderName?: string;
}

export interface ClipboardSnapshot {
  current: ClipboardEntry | null;
  history: ClipboardEntry[];
}

export interface StickyError {
  id: string;
  message: string;
  transferId?: string;
  createdAt: string;
}

export interface PeerStatusSnapshot {
  local: LocalDeviceInfo;
  peers: StickyDevice[];
}

export interface ClearErrorsResponse {
  cleared: number;
}
