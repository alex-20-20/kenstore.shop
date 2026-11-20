const SUPA_URL='https://gnophtajdfjnnuqgengd.supabase.co';
const SUPA_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdub3BodGFqZGZqbm51cWdlbmdkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTUwOTczODEsImV4cCI6MjExMDY3MzM4MX0.xBfTtENJdK7ck-KRMFl75mm2-DE0YqtaH3BvQmkF9AM';
function kenClient(admin = false) {
  return window.supabase?.createClient(SUPA_URL, SUPA_KEY, {
    auth: { storageKey: admin ? 'ks-admin-auth' : 'ks-shop-auth' }
  });
}
async function kenResult(request) {
  const { data, error } = await request;
  if (error) throw error;
  return data;
}
function kenReadCatalog(client) {
  return kenResult(client.from('store_catalog').select('products,categories,subcategories,site,updated_at').eq('id', 1).maybeSingle());
}

if (typeof module !== 'undefined') module.exports = { SUPA_URL, SUPA_KEY };

function cardBenefit(product){
  if(typeof product.cardBenefit==='string'&&product.cardBenefit.trim())return product.cardBenefit.trim();
  const tags=Array.isArray(product.pills)?product.pills.map(tag=>String(tag).trim()).filter(Boolean):[];
  const redundant=[product.n,product.t].map(value=>String(value||'').toLowerCase());
  const useful=tags.filter(tag=>tag.length<=18&&!redundant.some(text=>text.includes(tag.toLowerCase()))
    && !/^(?:gratis|entrega inmediata|\d+\s*(?:días?|mes(?:es)?|años?))$/iu.test(tag));
  return useful.find(tag=>/\b4K\b/i.test(tag))||useful[0]||'';
}
