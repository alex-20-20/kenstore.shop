import project from '../kenstore-data.js';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return res.status(405).json({ error: 'Método no permitido.' });
  }
  const authorization = req.headers?.authorization;
  if (typeof authorization !== 'string' || !/^Bearer [^\s]+$/i.test(authorization)) {
    return res.status(401).json({ error: 'Se requiere una sesión.' });
  }
  try {
    const user = await fetch(new URL('/auth/v1/user', process.env.SUPABASE_URL || project.SUPA_URL), {
      headers: { apikey: process.env.SUPABASE_ANON_KEY || project.SUPA_KEY, Authorization: authorization },
      signal: AbortSignal.timeout(5000)
    });
    if (user.status === 401 || user.status === 403) return res.status(401).json({ error: 'Sesión inválida.' });
    if (!user.ok) throw new Error('No se pudo consultar la sesión.');
    if ((await user.json()).app_metadata?.kenstore_admin !== true) {
      return res.status(403).json({ error: 'Se requieren permisos de administrador.' });
    }

    const { KEN_ANALYTICS_TOKEN, KEN_ANALYTICS_PROJECT_ID, KEN_ANALYTICS_TEAM_ID } = process.env;
    if (!KEN_ANALYTICS_TOKEN || !KEN_ANALYTICS_PROJECT_ID) {
      return res.status(200).json({ configured: false });
    }
    const endpoint = new URL('https://api.vercel.com/v1/query/web-analytics/visits/count');
    endpoint.searchParams.set('projectId', KEN_ANALYTICS_PROJECT_ID);
    if (KEN_ANALYTICS_TEAM_ID) endpoint.searchParams.set('teamId', KEN_ANALYTICS_TEAM_ID);
    endpoint.searchParams.set('filter', "requestPath eq '/'");
    const result = await fetch(endpoint, {
      headers: { Authorization: 'Bearer ' + KEN_ANALYTICS_TOKEN },
      signal: AbortSignal.timeout(7000)
    });
    if (!result.ok) throw new Error('Vercel Analytics no está disponible.');
    const { visitors, pageviews } = (await result.json()).data ?? {};
    if (![visitors, pageviews].every(value => Number.isSafeInteger(value) && value >= 0)) {
      throw new Error('Respuesta de Analytics inválida.');
    }
    return res.status(200).json({ configured: true, visitors, pageviews });
  } catch {
    return res.status(502).json({ error: 'No se pudieron consultar las visitas.' });
  }
}
