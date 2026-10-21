import { pool } from "./db.js";
import { EXCHANGE, getChannel } from "./broker.js";
import { EVENT_TYPES, type TransferResultPayload } from "./events.js";

const QUEUE = "payments.transfer-results.queue";

export async function startConsumer() {
  const channel = await getChannel();
  await channel.assertQueue(QUEUE, { durable: true });
  await channel.bindQueue(QUEUE, EXCHANGE, EVENT_TYPES.TRANSFER_COMPLETED);
  await channel.bindQueue(QUEUE, EXCHANGE, EVENT_TYPES.TRANSFER_FAILED);
  channel.prefetch(10);

  channel.consume(QUEUE, async (msg) => {
    if (!msg) return;
    try {
      const event: TransferResultPayload = JSON.parse(msg.content.toString());
      const status = msg.fields.routingKey === EVENT_TYPES.TRANSFER_COMPLETED ? "completed" : "failed";
      await applyResult(event, status);
      channel.ack(msg);
    } catch (err) {
      console.error("payments-service: failed to process result, requeueing", err);
      channel.nack(msg, false, true);
    }
  });

  console.log("payments-service: consumer listening for transfer results");
}

async function applyResult(event: TransferResultPayload, status: "completed" | "failed") {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const already = await client.query("select 1 from processed_events where event_id = $1", [event.eventId]);
    if (already.rows.length > 0) {
      await client.query("COMMIT");
      return;
    }

    await client.query("update transfers set status = $1, reason = $2, updated_at = now() where id = $3", [
      status,
      event.reason ?? null,
      event.transferId,
    ]);
    await client.query("insert into processed_events (event_id) values ($1)", [event.eventId]);

    await client.query("COMMIT");
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}
