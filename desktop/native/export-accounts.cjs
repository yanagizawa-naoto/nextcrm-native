// Run through desktop/run-clean.cjs. The source transaction is read-only.
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');

(async () => {
  const output = process.argv[2];
  if (!output) throw new Error('Specify the private JSONL output path');
  fs.mkdirSync(path.dirname(output), { recursive: true, mode: 0o700 });
  const file = fs.openSync(output, 'wx', 0o600);
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
  const client = await pool.connect(); let count = 0;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    await client.query(`DECLARE account_export NO SCROLL CURSOR FOR
      SELECT row_to_json(a)::jsonb || jsonb_build_object('owner_name',COALESCE(u.name,''),'industry_name',COALESCE(i.name,'')) AS data
      FROM "crm_Accounts" a LEFT JOIN "Users" u ON u.id=a.assigned_to
      LEFT JOIN "crm_Industry_Type" i ON i.id=a.industry
      WHERE a."deletedAt" IS NULL ORDER BY a.id`);
    while (true) {
      const { rows } = await client.query('FETCH FORWARD 200 FROM account_export');
      if (!rows.length) break;
      for (const row of rows) { fs.writeSync(file, JSON.stringify(row.data) + '\n'); count++; }
    }
    await client.query('COMMIT'); fs.fsyncSync(file);
    console.log(JSON.stringify({ exportedAccounts: count, output }));
  } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
  finally { fs.closeSync(file); client.release(); await pool.end(); }
})().catch(error => { console.error(error.message); process.exit(1); });
