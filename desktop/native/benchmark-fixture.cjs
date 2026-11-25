// Run with desktop/run-clean.cjs. Creates/removes only a manifest-owned synthetic dataset.
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { Pool } = require('pg');
const manifest = path.resolve('desktop/artifacts/native-benchmark-fixture.json');
(async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
  const client = await pool.connect();
  try {
    if (process.argv[2] === 'create') {
      if (fs.existsSync(manifest)) throw new Error('Fixture manifest already exists');
      const count = await client.query('SELECT count(*)::int AS n FROM "crm_Accounts"');
      if (count.rows[0].n !== 0) throw new Error('Benchmark requires the verified empty source database');
      const { rows: users } = await client.query('SELECT id FROM "Users" WHERE email=$1', ['local@nextcrm.local']);
      if (users.length !== 1) throw new Error('Local benchmark user not found');
      const prefix = 'ネイティブ比較用-20261114-';
      const rows = Array.from({ length: 1000 }, (_, n) => ({ id: randomUUID(), name: prefix + String(n + 1).padStart(4, '0') }));
      fs.writeFileSync(manifest, JSON.stringify({ prefix, rows }, null, 2), { flag: 'wx', mode: 0o600 });
      await client.query('BEGIN');
      for (let n = 0; n < rows.length; n++) {
        await client.query(`INSERT INTO "crm_Accounts"
          (id,"__v",name,email,office_phone,status,"createdBy",assigned_to,billing_state,billing_city,billing_country,description)
          VALUES ($1,0,$2,$3,$4,'Active',$5,$5,'東京都','千代田区','日本',$6)`,
          [rows[n].id, rows[n].name, `benchmark-${n + 1}@example.invalid`, `03-0000-${String(n + 1).padStart(4, '0')}`, users[0].id, 'メモリ比較専用の架空の取引先です。']);
      }
      await client.query('COMMIT');
      console.log(JSON.stringify({ created: rows.length, manifest }));
    } else if (process.argv[2] === 'cleanup') {
      const fixture = JSON.parse(fs.readFileSync(manifest, 'utf8'));
      await client.query('BEGIN');
      let removed = 0;
      for (const row of fixture.rows) {
        const result = await client.query('DELETE FROM "crm_Accounts" WHERE id=$1 AND name=$2', [row.id, row.name]);
        removed += result.rowCount;
      }
      if (removed !== fixture.rows.length) throw new Error(`Fixture mismatch: ${removed}`);
      await client.query('COMMIT');
      console.log(JSON.stringify({ removed, remaining: (await client.query('SELECT count(*)::int AS n FROM "crm_Accounts"')).rows[0].n }));
    } else throw new Error('Expected create or cleanup');
  } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
  finally { client.release(); await pool.end(); }
})().catch(error => { console.error(error.message); process.exit(1); });
