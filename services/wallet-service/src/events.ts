// Event contracts for the payments <-> wallet saga.
// Each service keeps its own copy of this file rather than importing a
// shared package at runtime — that's deliberate. In a real system this
// would be a versioned schema (e.g. published as an npm package or JSON
// schema), but services should never share live code/modules; the
// boundary is the message contract, not a shared library.

export const EVENT_TYPES = {
  TRANSFER_INITIATED: "payments.transfer.initiated",
  TRANSFER_COMPLETED: "wallet.transfer.completed",
  TRANSFER_FAILED: "wallet.transfer.failed",
} as const;

export interface TransferInitiatedPayload {
  eventId: string;
  transferId: string;
  fromWalletId: string;
  toWalletId: string;
  amountMinor: number;
  currency: string;
}

export interface TransferResultPayload {
  eventId: string;
  transferId: string;
  reason?: string;
}
