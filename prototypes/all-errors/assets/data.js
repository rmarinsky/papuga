/* Papuga "Помилки введення" — shared demo dataset.
   Drawn from the user's REAL mistake-observations (anonymised, representative).
   kind: 'typo' (has confident target) | 'domain' (your jargon, no target) | 'gibberish'
*/
window.PAPUGA_DEMO = (function () {
  const E = (id, source, target, lang, count, app, last, kind, cands, fam) => ({
    id, source, target: target || null, lang, count, app, last, kind,
    cands: cands || [], fam: fam || null,
  });

  // ---- the long tail (representative sample of 819 open) ----
  const errors = [
    // typos WITH a confident target (the minority — ~the actionable rule cases)
    E('e01','ghbdtn','привіт','uk',12,'Codex','сьогодні','typo',[['привіт','layout'],['привид','spell']]),
    E('e02','кщьфт','roman','uk',6,'Codex','вчора','typo',[['roman','layout']]),
    E('e03','поачати','почати','uk',4,'Cursor','сьогодні','typo',[['почати','spell']]),
    E('e04','блідай','білдай','uk',3,'Codex','вчора','typo',[['білдай','spell']]),
    E('e05','шось','щось','uk',3,'Telegram','вчора','typo',[['щось','spell']]),
    E('e06','ntcn','test','en',3,'Terminal','2 дні','typo',[['test','layout']]),
    E('e07','помилак','помилка','uk',2,'Notes','2 дні','typo',[['помилка','spell']]),
    E('e08','первірку','перевірку','uk',2,'Cursor','3 дні','typo',[['перевірку','spell']],'fam-perev'),
    E('e09','перевріку','перевірку','uk',2,'Cursor','3 дні','typo',[['перевірку','spell']],'fam-perev'),
    E('e10','превірку','перевірку','uk',1,'Telegram','тиждень','typo',[['перевірку','spell']],'fam-perev'),
    E('e11','мможе','може','uk',2,'Telegram','3 дні','typo',[['може','spell']],'fam-mozhe'),
    E('e12','можес','може','uk',1,'Telegram','тиждень','typo',[['може','spell']],'fam-mozhe'),
    E('e13','правльно','правильно','uk',2,'Cursor','4 дні','typo',[['правильно','spell']],'fam-prav'),
    E('e14','праивльно','правильно','uk',1,'Codex','тиждень','typo',[['правильно','spell']],'fam-prav'),
    E('e15','teh','the','en',2,'Teams','3 дні','typo',[['the','spell']],'fam-the'),
    E('e16','дєплой','деплой','uk',2,'Codex','4 дні','typo',[['деплой','spell']]),

    // domain words — YOUR vocabulary, no confident target (the MAJORITY → dictionary)
    E('e20','пофіксити',null,'uk',8,'Codex','сьогодні','domain'),
    E('e21','віджет',null,'uk',9,'Cursor','сьогодні','domain'),
    E('e22','репозиторії',null,'uk',7,'Cursor','вчора','domain'),
    E('e23','фідбек',null,'uk',5,'Telegram','вчора','domain'),
    E('e24','плейрайт',null,'uk',3,'Codex','2 дні','domain'),
    E('e25','пайплайн',null,'uk',3,'Codex','2 дні','domain'),
    E('e26','ресьорч',null,'uk',3,'Cursor','2 дні','domain'),
    E('e27','перевикористати',null,'uk',3,'Cursor','3 дні','domain'),
    E('e28','вейфорпей',null,'uk',3,'Cursor','3 дні','domain'),
    E('e29','захардкодити',null,'uk',2,'Codex','3 дні','domain'),
    E('e30','аксептити',null,'uk',2,'Teams','4 дні','domain'),
    E('e31','юзати',null,'uk',2,'Telegram','4 дні','domain'),
    E('e32','редизайн',null,'uk',2,'Cursor','4 дні','domain'),
    E('e33','ліквід',null,'uk',2,'Notes','тиждень','domain'),
    E('e34','шорткат',null,'uk',2,'Notes','тиждень','domain'),
    E('e35','інстал',null,'uk',2,'Terminal','тиждень','domain'),
    E('e36','темплейтах',null,'uk',2,'Cursor','тиждень','domain','','fam-templ'),
    E('e37','темплейту',null,'uk',2,'Cursor','тиждень','domain','','fam-templ'),
    E('e38','темплейти',null,'uk',1,'Cursor','тиждень','domain','','fam-templ'),
    E('e39','анґліцизм',null,'uk',1,'Notes','тиждень','domain'),

    // gibberish / mojibake fragments → hide
    E('e50','jdfhjdhf',null,'en',1,'Terminal','2 дні','gibberish'),
    E('e51','поцію.',null,'uk',1,'Codex','3 дні','gibberish'),
    E('e52','yoy.event.',null,'en',1,'Cursor','3 дні','gibberish'),
    E('e53','dsl;tn',null,'uk',1,'Codex','4 дні','gibberish'),
    E('e54','кнокп',null,'uk',1,'Telegram','тиждень','gibberish'),
  ];

  // ---- similarity families (clusters) ----
  const families = [
    { id:'fam-perev', target:'перевірку', lang:'uk', kind:'typo',
      members:['первірку','перевріку','превірку'], count:5 },
    { id:'fam-mozhe', target:'може', lang:'uk', kind:'typo',
      members:['мможе','можес','можі'], count:4 },
    { id:'fam-prav', target:'правильно', lang:'uk', kind:'typo',
      members:['правльно','праивльно'], count:3 },
    { id:'fam-templ', target:null, lang:'uk', kind:'domain', rep:'темплейт',
      members:['темплейтах','темплейту','темплейти','темплейт'], count:5 },
    { id:'fam-the', target:'the', lang:'en', kind:'typo',
      members:['teh','seee','hte'], count:5 },
    { id:'fam-mozhl', target:'можливість', lang:'uk', kind:'typo',
      members:['можиливість','можливіть'], count:2 },
  ];

  // ---- decision buckets (headline totals are the REAL distribution; sample = items above) ----
  const buckets = [
    { id:'domain', icon:'🟢', tone:'accent', title:'Схоже на твої слова',
      hint:'словоподібні, без впевненої заміни, повторюються — це твій сленг',
      total:612, action:'Зберегти всі в словник',
      sample: errors.filter(e=>e.kind==='domain') },
    { id:'typo', icon:'🟡', tone:'amber', title:'Ймовірні одруки',
      hint:'є впевнена заміна → можна зробити правило',
      total:141, action:'Створити 141 правило',
      sample: errors.filter(e=>e.kind==='typo') },
    { id:'rare', icon:'⚪️', tone:'slate', title:'Рідкісні / разові (1×)',
      hint:'трапилися лише раз — найнижчий пріоритет',
      total:52, action:'Зберегти всі в словник',
      sample: errors.filter(e=>e.count===1 && e.kind!=='gibberish').slice(0,6) },
    { id:'gibberish', icon:'🔴', tone:'rose', title:'Незрозумілі',
      hint:'мойібейк, пунктуація, обрізки — користі нема',
      total:14, action:'Сховати всі',
      sample: errors.filter(e=>e.kind==='gibberish') },
  ];

  // ---- grouping by app (where you mistype) ----
  const APP_META = {
    Codex:   { glyph:'⌘', sub:'AI / код' },
    Cursor:  { glyph:'▢', sub:'редактор коду' },
    Telegram:{ glyph:'✈', sub:'чат' },
    Teams:   { glyph:'◳', sub:'робочий чат' },
    Terminal:{ glyph:'>_', sub:'термінал' },
    Notes:   { glyph:'≣', sub:'нотатки' },
  };
  // real totals per app (open) so headline numbers feel true
  const APP_TOTAL = { Codex:265, Cursor:192, Telegram:94, Teams:65, Terminal:63, Notes:27 };
  const byApp = Object.keys(APP_TOTAL).map(name => ({
    name, glyph: APP_META[name].glyph, sub: APP_META[name].sub,
    total: APP_TOTAL[name],
    items: errors.filter(e => e.app === name),
  }));

  // ---- review queue (ordered by value: confident+frequent first) ----
  const queue = errors
    .filter(e => e.kind !== 'gibberish')
    .sort((a,b) => (b.count*(b.target?1.6:1)) - (a.count*(a.target?1.6:1)));

  // ---- header stats + usefulness counter ----
  const stats = {
    open: 819,          // open mistakes
    repeated: 47,       // recurring (>=2x)
    rules: 82,          // converted to replacement rules
    dict: 200,          // saved to dictionary
    observed: 1046,     // total ever seen
    fixed: 282,         // rules + dict
    pct: 27,            // fixed / observed
    savedMin: 7.5,      // estimated minutes saved by rules so far
  };

  return { errors, families, buckets, byApp, queue, stats };
})();
