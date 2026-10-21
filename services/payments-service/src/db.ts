import pg from "pg";

export const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

export async function waitForDb() {
  for (let attempt = 1; attempt <= 20; attempt++) {
    try {
      await pool.query("select 1");
      return;
    } catch {
      console.log(`payments-service: waiting for postgres (attempt ${attempt})`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error("payments-service: could not connect to postgres");
}
