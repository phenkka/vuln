// Frontend VulnShop. Уязвимости намеренные (DOM XSS, eval, prototype pollution).
const params = new URLSearchParams(location.search);
const q = params.get('q');

// DOM XSS: пользовательский ввод напрямую в innerHTML
if (q) {
  document.getElementById('result').innerHTML = 'Results for: ' + q;
}

// DOM XSS через jQuery .html()
if (params.get('msg')) {
  $('#banner').html(params.get('msg'));
}

// Code injection: eval от location.hash
function show_home() { console.log('home'); }
if (location.hash) {
  eval('show_' + location.hash.slice(1) + '()');
}

// Prototype pollution: небезопасный _.merge с данными из URL
const defaults = { theme: 'light' };
const prefs = _.merge({}, defaults, JSON.parse(params.get('prefs') || '{}'));
console.log('prefs', prefs);

// Запрос к backend через устаревший axios
if (q) {
  axios.get('/app/search', { params: { q: q } }).then(function (r) {
    $('#items').html(r.data);
  });
}
