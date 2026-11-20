import project from '../kenstore-data.js';

const orderStates = new Set(['pendiente', 'aceptado', 'en_proceso', 'entregado', 'rechazado']);

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Método no permitido.' });
  }

  const authorization = req.headers?.authorization;
  if (typeof authorization !== 'string' || !/^Bearer [^\s]+$/i.test(authorization)) {
    return res.status(401).json({ error: 'Se requiere una sesión.' });
  }

  const { id, status, reason = '' } = req.body ?? {};
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(id) ||
      !orderStates.has(status) || typeof reason !== 'string' || reason.length > 180) {
    return res.status(400).json({ error: 'Datos del pedido inválidos.' });
  }

  const url = process.env.SUPABASE_URL || project.SUPA_URL;
  const publicKey = process.env.SUPABASE_ANON_KEY || project.SUPA_KEY;
  if (!url || !publicKey) {
    return res.status(503).json({ error: 'Falta configurar Supabase.' });
  }

  try {
    const headers = { apikey: publicKey, Authorization: authorization };
    const userResponse = await fetch(new URL('/auth/v1/user', url), { headers });
    if (userResponse.status === 401 || userResponse.status === 403) {
      return res.status(401).json({ error: 'Sesión inválida o vencida.' });
    }
    if (!userResponse.ok) throw new Error('No se pudo verificar la sesión.');
    const user = await userResponse.json();
    if (user.app_metadata?.kenstore_admin !== true) {
      return res.status(403).json({ error: 'Se requieren permisos de administrador.' });
    }

    const endpoint = new URL('/rest/v1/orders', url);
    endpoint.searchParams.set('id', 'eq.' + id);
    endpoint.searchParams.set('select', 'id');
    const update = await fetch(endpoint, {
      method: 'PATCH',
      headers: { ...headers, 'Content-Type': 'application/json', Prefer: 'return=representation' },
      body: JSON.stringify({ status, reason: status === 'rechazado' ? reason.trim() : '' })
    });
    if (!update.ok) {
      const error = await update.json().catch(() => null);
      if (error?.message === 'KEN_OUT_OF_STOCK') return res.status(409).json({ code: 'OUT_OF_STOCK' });
      if (error?.message === 'KEN_UNAVAILABLE') return res.status(409).json({ code: 'PRODUCT_REMOVED' });
      throw new Error('Supabase rechazó la actualización.');
    }
    const rows = await update.json();
    if (rows.length === 0) return res.status(404).json({ error: 'Pedido no encontrado.' });
    return res.status(200).json({ ok: true });
  } catch (error) {
    console.error('Ken Store order update failed:', error.message);
    return res.status(502).json({ error: 'No se pudo actualizar el pedido.' });
  }
}
