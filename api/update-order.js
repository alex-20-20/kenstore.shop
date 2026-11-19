export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { id, status, reason } = req.body;
  if (!id || !status) return res.status(400).json({ error: 'Missing fields' });

  const SUPA_URL = process.env.SUPABASE_URL;
  const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;

  if (!SUPA_URL || !SERVICE_KEY) return res.status(500).json({ error: 'Missing env vars' });

  const r = await fetch(`${SUPA_URL}/rest/v1/orders?id=eq.${id}`, {
    method: 'PATCH',
    headers: {
      'apikey': SERVICE_KEY,
      'Authorization': `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal'
    },
    body: JSON.stringify({ status, reason: reason || '' })
  });

  if (!r.ok) {
    const e = await r.json().catch(() => ({}));
    return res.status(r.status).json({ error: e });
  }

  return res.status(200).json({ ok: true });
}
