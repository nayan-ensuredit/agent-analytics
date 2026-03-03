import pg from 'pg';
import { readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';
import 'dotenv/config';

// Parse ~/.pgpass to get password (local dev fallback)
function getPgPassword() {
  // Prefer environment variable (used in Vercel / production)
  if (process.env.DB_PASSWORD) return process.env.DB_PASSWORD;

  try {
    const pgpassPath = join(homedir(), '.pgpass');
    const content = readFileSync(pgpassPath, 'utf-8');
    const lines = content.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
    for (const line of lines) {
      const parts = line.split(':', 4);
      if (parts.length < 4) continue;
      const [host, port, db, user] = parts;
      if ((host === '*' || host === process.env.DB_HOST || host === '13.201.42.25') &&
          (port === '*' || port === String(process.env.DB_PORT || '5432')) &&
          (db === '*' || db === (process.env.DB_NAME || 'masterdata')) &&
          (user === '*' || user === (process.env.DB_USER || 'rohit'))) {
        const password = line.slice(parts.join(':').length + 1);
        return password;
      }
    }
    console.error('No matching entry found in ~/.pgpass');
    return '';
  } catch (err) {
    console.error('Failed to read ~/.pgpass:', err.message);
    return '';
  }
}

const pool = new pg.Pool({
  host: process.env.DB_HOST || '13.201.42.25',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME || 'masterdata',
  user: process.env.DB_USER || 'rohit',
  password: getPgPassword(),
  max: process.env.VERCEL ? 3 : 10,           // fewer connections in serverless
  idleTimeoutMillis: process.env.VERCEL ? 10000 : 30000,
  connectionTimeoutMillis: 10000,
  statement_timeout: 60000,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

pool.on('error', (err) => {
  console.error('Unexpected PG pool error:', err);
});

export async function query(sql, params = []) {
  const start = Date.now();
  const result = await pool.query(sql, params);
  const duration = Date.now() - start;
  if (duration > 5000) {
    console.warn(`Slow query (${duration}ms):`, sql.substring(0, 80));
  }
  return result;
}

export async function testConnection() {
  try {
    const res = await pool.query('SELECT NOW()');
    console.log('DB connected:', res.rows[0].now);
    return true;
  } catch (err) {
    console.error('DB connection failed:', err.message);
    return false;
  }
}

export default pool;
