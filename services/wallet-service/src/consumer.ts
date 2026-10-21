import { pool } from "./db.js";
import { EXCHANGE, getChannel } from "./broker.js";
import { EVENT_TYPES, type TransferInitiatedPayload } from "./events.js";

const QUEUE = "wallet.transfer-initiated.queue";

export async function startConsumer() {
  const channel = await getChannel();
  await channel.assertQueue(QUEUE, { durable: true });
  await channel.bindQueue(QUEUE, EXCHANGE, EVENT_TYPES.TRANSFER_INITIATED);
  channel.prefetch(10);

  channel.consume(QUEUE, async (msg) => {
    if (!msg) return;

    try {
      const event: TransferInitiatedPayload = JSON.parse(msg.content.toString());
      await handleTransferInitiated(event);
      channel.ack(msg);
    } catch (err) {
      console.error("wallet-service: failed to process message, requeueing", err);
      // requeue=true: a transient DB blip should be retried, not dropped.
      // A real system would add a retry-count header and dead-letter after
      // N attempts to avoid a poison message looping forever.
      channel.nack(msg, false, true);
    }
  });

  console.log("wallet-service: consumer listening for", EVENT_TYPES.TRANSFER_INITIATED);
}

async function handleTransferInitiated(event: TransferInitiatedPayload) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    // Idempotency: if we've already processed this exact event (e.g. broker
    // redelivered it after we committed but before we acked), skip re-applying
    // the balance change but still let the message ack normally.
    const already = await client.query("select 1 from processed_events where event_id = $1", [event.eventId]);
    if (already.rows.length > 0) {
      await client.query("COMMIT");
      return;
    }

    const { rows: walletRows } = await client.query(
      "select id, balance_minor from wallets where id in ($1, $2) for update",
      [event.fromWalletId, event.toWalletId]
    );

    const fromWallet = walletRows.find((w) => w.id === event.fromWalletId);
    const toWallet = walletRows.find((w) => w.id === event.toWalletId);

    if (!fromWallet || !toWallet) {
      await writeOutboxResult(client, event, "wallet_not_found");
      await client.query("COMMIT");
      return;
    }

    if (fromWallet.balance_minor < event.amountMinor) {
      await writeOutboxResult(client, event, "insufficient_funds");
      await client.query("COMMIT");
      return;
    }

    await client.query("update wallets set balance_minor = balance_minor - $1 where id = $2", [
      event.amountMinor,
      event.fromWalletId,
    ]);
    await client.query("update wallets set balance_minor = balance_minor + $1 where id = $2", [
      event.amountMinor,
      event.toWalletId,
    ]);

    // Two ledger rows per transfer — debit and credit — always summing to
    // zero. This is the durable, auditable record; `wallets.balance_minor`
    // is a derived cache for fast reads.
    await client.query(
      "insert into ledger_entries (wallet_id, transfer_id, direction, amount_minor) values ($1, $2, 'debit', $3)",
      [event.fromWalletId, event.transferId, event.amountMinor]
    );
    await client.query(
      "insert into ledger_entries (wallet_id, transfer_id, direction, amount_minor) values ($1, $2, 'credit', $3)",
      [event.toWalletId, event.transferId, event.amountMinor]
    );

    await writeOutboxResult(client, event, undefined);
    await client.query("COMMIT");
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

async function writeOutboxResult(
  client: import("pg").PoolClient,
  event: TransferInitiatedPayload,
  reason: string | undefined
) {
  const eventType = reason ? EVENT_TYPES.TRANSFER_FAILED : EVENT_TYPES.TRANSFER_COMPLETED;
  const payload = { eventId: crypto.randomUUID(), transferId: event.transferId, reason };
  await client.query("insert into outbox (event_type, payload) values ($1, $2)", [
    eventType,
    JSON.stringify(payload),
  ]);
  await client.query("insert into processed_events (event_id) values ($1) on conflict do nothing", [
    event.eventId,
  ]);
}
