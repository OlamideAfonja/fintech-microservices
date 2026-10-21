import amqp, { type ChannelModel, type Channel } from "amqplib";

export const EXCHANGE = "fintech.events";

let connection: ChannelModel | undefined;
let channel: Channel | undefined;

export async function getChannel(): Promise<Channel> {
  if (channel) return channel;

  for (let attempt = 1; attempt <= 20; attempt++) {
    try {
      connection = await amqp.connect(process.env.RABBITMQ_URL ?? "amqp://localhost:5672");
      channel = await connection.createChannel();
      await channel.assertExchange(EXCHANGE, "topic", { durable: true });
      return channel;
    } catch {
      console.log(`wallet-service: waiting for rabbitmq (attempt ${attempt})`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error("wallet-service: could not connect to rabbitmq");
}
