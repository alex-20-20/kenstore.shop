const fs = require('node:fs');

const home = 'index.html';
const placeholder = '<!-- vercel-web-analytics -->';
const html = fs.readFileSync(home, 'utf8');
const config = JSON.parse(process.env.VERCEL_OBSERVABILITY_CLIENT_CONFIG || '{}');
const { scriptSrc, viewEndpoint, eventEndpoint } = config.analytics || {};
const isLocalPath = value => typeof value === 'string' && /^\/(?:[\w.-]+\/)*[\w.-]+$/.test(value);
if (!html.includes(placeholder)) throw new Error('Missing Analytics placeholder.');

if (isLocalPath(scriptSrc) && isLocalPath(viewEndpoint)) {
  const event = isLocalPath(eventEndpoint) ? ` data-event-endpoint="${eventEndpoint}"` : '';
  const script = `<script defer src="${scriptSrc}" data-view-endpoint="${viewEndpoint}"${event}></script>`;
  fs.writeFileSync(home, html.replace(placeholder, script));
  console.log('Web Analytics configured.');
} else {
  console.log('Web Analytics configuration is unavailable for this deployment.');
}
