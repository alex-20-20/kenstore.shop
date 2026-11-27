const fs = require('node:fs');
const path = require('node:path');

const output = 'public';
const assets = [
  'index.html', 'keen-store-admin.html', 'keen-store-rediseno-v20.html',
  'kenstore-data.js', 'ken-catalog.webmanifest', 'ken-catalog-dragon-192.png', 'ken-catalog-dragon-512.png', 'ken-catalog-dragon-front-192.png', 'ken-catalog-dragon-front-512.png', 'ken-admin.webmanifest', 'ken-admin-sw.js',
  'ken-admin-192.png', 'ken-admin-512.png', 'robots.txt', 'sitemap.xml'
];
fs.mkdirSync(output, { recursive: true });
for (const name of assets) fs.copyFileSync(name, path.join(output, name));

fs.cpSync('store-assets', path.join(output, 'store-assets'), { recursive: true });

const home = path.join(output, 'index.html');
const placeholder = '<!-- vercel-web-analytics -->';
const html = fs.readFileSync(home, 'utf8');
let analytics;
try {
  analytics = JSON.parse(process.env.VERCEL_OBSERVABILITY_CLIENT_CONFIG || '{}').analytics;
} catch {
  console.warn('Web Analytics configuration is invalid.');
}
const { scriptSrc, viewEndpoint, eventEndpoint } = analytics || {};
const isLocalPath = value => typeof value === 'string' && /^\/(?:[\w.-]+\/)*[\w.-]+$/.test(value);
if (isLocalPath(scriptSrc) && isLocalPath(viewEndpoint)) {
  const event = isLocalPath(eventEndpoint) ? ` data-event-endpoint="${eventEndpoint}"` : '';
  const script = `<script defer src="${scriptSrc}" data-view-endpoint="${viewEndpoint}"${event}></script>`;
  fs.writeFileSync(home, html.replace(placeholder, script));
  console.log('Web Analytics configured.');
} else {
  console.log('Web Analytics configuration is unavailable for this deployment.');
}
