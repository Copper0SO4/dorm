'use strict';
const by = id => document.getElementById(id);
const content = by('content');
const dialog = by('dialog');
const codePattern = /^[2-9A-HJ-NP-Z]{7}$/;
const queryRoom = new URL(location.href).searchParams.get('room')?.toUpperCase();
const modes = {classic:'经典',wild:'癞子',doubleWild:'天地癞子'};
let session = null;
let state = null;
let selected = new Set();
let currentEvents = 0;
let pending = false;
let noticeTimer;
let muted = false;
let context;

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [key,value] of Object.entries(attrs ?? {})) {
    if (value != null && value !== false) node.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child != null) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}
function button(label, action, opts = {}) {
  const node = el('button', {type:'button',class:opts.design,disabled:opts.disabled,title:opts.title}, label);
  node.addEventListener('click', () => run(action));
  return node;
}
function line(label, control) { return el('label', {}, label, control); }
function select(name, entries, current) {
  const node = el('select', {name}, entries.map(([key,label]) => el('option', {value:key,selected:key === current}, label)));
  return node;
}
function number(name, value, min, max) {
  return el('input', {name,type:'number',value,min,max,step:1,required:true});
}
function check(name, label, checked) {
  return el('label', {class:'toggle'},el('input',{name,type:'checkbox',checked}),label);
}
function notice(text) {
  const item = by('notice');
  item.hidden = false;
  item.textContent = text;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => { item.hidden = true; }, 3600);
}
async function run(action) { try { await action(); } catch (error) { notice(error.message || '操作失败'); } }
function loadAudio() {
  try {
    const WebAudio = window.AudioContext || window.webkitAudioContext;
    if (!context && WebAudio) context = new WebAudio();
    if (context?.state === 'suspended') context.resume().catch(() => {});
  } catch (_) {}
}
function sound(kind) {
  if (!context || muted || context.state !== 'running') return;
  const tones = {
    deal:[353,442,528],landlord:[393,523,659],play:[230],pass:[155],bid:[312,416],
    bomb:[140,85,56],rocket:[450,680,910],finish:[392,494,587,784],tomato:[360,170,92],chat:[520,680],
  }[kind] ?? [];
  tones.forEach((frequency, i) => {
    const start = context.currentTime + i * .055;
    const generator = context.createOscillator();
    const gain = context.createGain();
    generator.type = ['bomb','tomato'].includes(kind) ? 'triangle' : 'sine';
    generator.frequency.setValueAtTime(frequency, start);
    generator.frequency.exponentialRampToValueAtTime(frequency * .78, start + .14);
    gain.gain.setValueAtTime(.12, start);
    gain.gain.exponentialRampToValueAtTime(.001, start + .15);
    generator.connect(gain).connect(context.destination);
    generator.start(start);
    generator.stop(start + .16);
  });
}
by('audio').addEventListener('click', () => {
  muted = !muted;
  if (!muted) loadAudio();
  by('audio').textContent = muted ? '开启音效' : '关闭音效';
  by('audio').setAttribute('aria-pressed', muted ? 'true' : 'false');
});

async function request(path, data, seat = session) {
  const headers = {};
  if (seat?.token) headers['X-Dorm-Seat'] = seat.token;
  if (data !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch('/api/cards' + path,{
    method:data === undefined ? 'GET' : 'POST',headers,cache:'no-store',
    body:data === undefined ? undefined : JSON.stringify(data),
    signal:AbortSignal.timeout(7000),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '无法连接牌桌');
  return result;
}
function openDialog(title, ...parts) {
  dialog.replaceChildren(el('div',{class:'stack'},el('h2',{},title),parts));
  if (!dialog.open) dialog.showModal();
}
function enter(next) {
  session = next;
  state = null;
  currentEvents = 0;
  selected.clear();
  try { sessionStorage.setItem('dorm-cards:' + next.room, next.token); } catch (_) {}
  const target = new URL(location.href);
  target.searchParams.set('room', next.room);
  history.replaceState(null,'',target);
  return refresh();
}
function chooseIdentity(action) {
  loadAudio();
  const name = el('input',{maxlength:20,placeholder:'可填写昵称'});
  openDialog('选择上桌身份',line('牌桌昵称（可选）',name),
    el('div',{class:'actions'},
      button('取消',() => dialog.close()),
      button('跳过，匿名加入',() => {dialog.close();return action('');}),
      button('用昵称继续',() => {dialog.close();return action(name.value.trim());},{design:'primary'})));
}
function rulesForm(previous = null) {
  const old = previous ?? {players:3,decks:1,discard:0,bottom:3,mode:'classic',landlord:true,remainder:'equal'};
  const players = number('players',old.players,2,8);
  const decks = number('decks',old.decks,1,4);
  const discard = number('discard',old.discard,0,210);
  const bottom = number('bottom',old.bottom || 3,1,30);
  const mode = select('mode',Object.entries(modes),old.mode);
  const remainder = select('remainder',[['equal','必须平分'],['extra','随机多发给一人']],old.remainder);
  const landlord = check('landlord','启用地主',old.landlord);
  const reserve = check('reserve','给地主底牌',old.bottom > 0);
  const summary = el('p',{class:'muted'});
  const reserveRow = el('div',{class:'stack'},reserve,line('底牌张数',bottom));
  function rule() {
    const hasLandlord = landlord.querySelector('input').checked;
    const hasBottom = hasLandlord && reserve.querySelector('input').checked;
    return {players:Number(players.value),decks:Number(decks.value),discard:Number(discard.value),
      landlord:hasLandlord,bottom:hasBottom ? Number(bottom.value) : 0,mode:mode.value,remainder:remainder.value};
  }
  function counts() {
    const r = rule();
    reserveRow.hidden = !r.landlord;
    bottom.disabled = !r.landlord || !reserve.querySelector('input').checked;
    const available = r.decks*54-r.bottom-r.discard;
    summary.textContent = r.players ? '起手每位 '+Math.max(0,Math.floor(available/r.players))+' 张 · 余 '+Math.max(0,available%r.players)+' 张' : '';
  }
  const form = el('form',{class:'stack'},
    line('玩法',mode),el('div',{class:'duo'},line('人数',players),line('副数',decks)),
    landlord,reserveRow,line('随机舍弃张数',discard),line('余牌处理',remainder),summary,
    el('div',{class:'actions'},
      button('取消',() => dialog.close()),
      button('自动补齐舍弃张数',() => {
        const r = rule(); if (r.players) discard.value = r.discard+(r.decks*54-r.bottom-r.discard)%r.players; counts();
      }),
      el('button',{type:'submit',class:'primary'},previous ? '保存规则' : '创建房间')));
  form.addEventListener('input',counts);
  form.addEventListener('submit',event => {
    event.preventDefault();
    const rules = rule();
    if (previous) run(async () => { await act('rules',{rules}); dialog.close(); });
    else chooseIdentity(async name => enter(await request('/create',{rules,name},null)));
  });
  openDialog(previous ? '调整房间规则' : '创建斗地主房间',form);
  counts();
}
function buildLobby(rooms) {
  const choices = rooms.map(room => el('article',{class:'room'},
    el('div',{},el('h3',{},room.host+'的牌桌'),el('small',{},room.players+'/'+room.capacity+' 人 · '+(modes[room.mode] ?? '斗地主'))),
    button('加入',() => chooseIdentity(async name => enter(await request('/'+room.room+'/join',{name},null))),{design:'primary'})));
  if (codePattern.test(queryRoom) && !rooms.some(item => item.room === queryRoom)) {
    choices.unshift(el('article',{class:'room'},el('div',{},el('h3',{},'邀请房间 '+queryRoom)),
      button('尝试加入',() => chooseIdentity(async name => enter(await request('/'+queryRoom+'/join',{name},null))))));
  }
  content.replaceChildren(el('div',{class:'stack'},
    el('div',{class:'actions'},button('创建房间',() => rulesForm(),{design:'primary'}),button('刷新',refresh)),
    el('h2',{},'局域网房间'),
    choices.length ? choices : el('p',{class:'muted'},'还没有可加入的牌桌。')));
}
const rankNames = {11:'J',12:'Q',13:'K',14:'A',15:'2',16:'小王',17:'大王'};
const rankName = rank => rankNames[rank] ?? String(rank);
const rankOf = id => id%54 < 52 ? 3+Math.floor((id%54)/4) : id%54-36;
function face(id, shown, clickable = false) {
  const raw = rankOf(id);
  const suit = id%54 < 52 ? id%4 : null;
  const wild = clickable && state.wild.includes(raw);
  const label = rankName(shown ?? raw);
  const mark = suit === null ? '★' : ['♠','♥','♦','♣'][suit];
  const attrs = {class:'face'+(suit===1 || suit===2 || raw===17 ? ' red':'')+(wild?' wild':'')};
  if (clickable) {
    attrs.type = 'button'; attrs['aria-pressed'] = String(selected.has(id));
    attrs['aria-label'] = label+' '+mark+(wild?' 癞子':'');
  }
  const node = el(clickable?'button':'span',attrs,el('span',{},label),el('small',{},wild?'癞':mark));
  if (clickable) node.addEventListener('click',() => {
    if (!selected.delete(id)) selected.add(id);
    node.setAttribute('aria-pressed',String(selected.has(id)));
    const play = by('play');
    if (play) {play.disabled = selected.size===0;play.textContent='出牌 · '+selected.size;}
  });
  return node;
}
const playerName = id => state?.people.find(person => person.id === id)?.name ?? '';
function renderRoom() {
  if (!state) return;
  const s = state;
  const own = s.you === s.turn;
  const host = s.you === s.host;
  const active = ['bidding','playing'].includes(s.phase);
  const title = s.phase === 'finished' ? s.result :
    s.phase === 'bidding' ? (own?'轮到你叫分':playerName(s.turn)+'正在叫分') :
    s.phase === 'playing' ? (own?'轮到你出牌':playerName(s.turn)+'正在出牌') : '等待发牌';
  const seat = p => el('div',{class:'seat'+(p.id===s.turn?' turn':''),'data-seat':p.id},p.name,
    el('small',{},(p.id===s.you?'我 · ':'')+(p.id===s.landlord?'地主 · ':'')+p.cards+' 张'),
    p.id===s.you?null:button('🍅',() => act('tomato',{target:p.id}),{title:'向'+p.name+'丢番茄'}));
  const actions = [];
  if (host && !active) {
    actions.push(button(s.phase==='finished'?'再来一局':'发牌开局',() => act('start'),{design:'primary',disabled:s.people.length!==s.rules.players}));
    actions.push(button('添加电脑玩家',() => act('bot'),{disabled:s.people.length>=s.rules.players}));
    if (s.people.some(p => p.bot)) actions.push(button('移除电脑玩家',() => act('removeBot')));
    actions.push(button('调整规则',() => rulesForm(s.rules)));
  }
  if (host && active) actions.push(button('结束牌局',() => {
    openDialog('结束当前牌局？',button('取消',() => dialog.close()),button('结束牌局',() => {dialog.close();return act('abort');}));
  }));
  if (own && s.phase==='bidding') {
    actions.push(button('不叫',() => act('bid',{bid:0})));
    for (let bid=s.bid+1;bid<=3;bid++) actions.push(button('叫 '+bid+' 分',() => act('bid',{bid}),{design:'primary'}));
  }
  if (own && s.phase==='playing') {
    const play = button('出牌 · '+selected.size,choosePlay,{design:'primary',disabled:selected.size===0});
    play.id='play';
    actions.push(play,button('不要',() => act('pass'),{disabled:!s.last}));
  }
  content.replaceChildren(el('div',{class:'stack'},
    el('div',{class:'room'},el('div',{},el('h2',{},'房间 '+s.room),el('small',{},modes[s.rules.mode]+' · '+s.rules.players+' 人 · '+s.rules.decks+' 副')),
      el('div',{class:'actions'},button('分享',share),button('离开',leave))),
    el('section',{class:'felt'},el('div',{class:'seats'},s.people.map(seat)),
      el('h2',{},title),
      s.wild.length?el('small',{},'癞子 · '+s.wild.map(rankName).join('、')):null,
      s.bottom.length?el('div',{class:'played'},'地主底牌',s.bottom.map(id => face(id))):null,
      s.last?el('div',{class:'played'},playerName(s.leader)+' · '+s.last.label,
        s.last.cards.map(card => face(card.id,card.rank))):null),
    el('div',{class:'actions'},actions),
    s.hand.length?el('div',{class:'stack'},el('h3',{},'我的手牌 · '+s.hand.length+' 张'),
      el('div',{class:'hand'},s.hand.map(id => face(id,null,s.phase==='playing')))):null,
    el('details',{class:'history'},
      el('summary',{},'牌桌聊天 · '+s.events.length+' 条'),
      s.events.slice().reverse().map(event => el('p',{},event.kind==='chat'?playerName(event.from)+' · '+event.text:event.text))),
  ));
  by('chat').hidden = false;
}
function share() {
  const input = el('input',{readonly:true,value:location.href,'aria-label':'牌桌链接'});
  openDialog('分享牌桌链接',input,button('选择链接',() => { input.focus();input.select(); }),
    button('完成',() => dialog.close()));
  input.select();
}
function leave() {
  openDialog('离开牌桌？',el('p',{},'进行中的牌局会结束。'),
    button('取消',() => dialog.close()),button('离开房间',async () => {
      await act('leave');
      dialog.close();
    },{design:'primary'}));
}
async function choosePlay() {
  const cards = [...selected];
  const revision = state.turnVersion;
  const {options} = await request('/'+session.room+'/options',{cards,turnVersion:revision});
  if (options.length === 1) return act('play',{cards,pattern:options[0].key},revision);
  openDialog('选择癞子替代方式',options.map(option =>
    button(option.label+' · '+rankName(option.high),() => {
      dialog.close();
      return act('play',{cards,pattern:option.key},revision);
    })),button('取消',() => dialog.close()));
}
async function act(action, data = {}, revision = state?.turnVersion) {
  if (pending || !session) return;
  pending = true;
  try {
    const value = await request('/'+session.room+'/'+action,{...data,turnVersion:revision});
    if (value.left) {
      try { sessionStorage.removeItem('dorm-cards:'+session.room); } catch (_) {}
      state = session = null;
      selected.clear();
      by('chat').hidden = true;
      await refresh(true);
    } else accept(value);
  } finally { pending = false; }
}
function accept(value) {
  if (!value.phase || (state && value.version <= state.version)) return;
  if (value.turnVersion !== state?.turnVersion) selected.clear();
  const events = state ? value.events.filter(item => item.id>currentEvents) : [];
  state = value;
  currentEvents = value.events.at(-1)?.id ?? 0;
  const wasOpen = content.querySelector('details')?.open;
  renderRoom();
  if (wasOpen) content.querySelector('details').open=true;
  const tomato = events.findLast(event => event.kind==='tomato');
  if (tomato) content.querySelector('[data-seat="'+tomato.target+'"]')?.classList.add('splat');
  if (events.some(event => ['rocket','bomb'].includes(event.kind))) {
    content.querySelector('.felt')?.classList.add('impact');
  }
  if (events.some(event => event.kind === 'deal')) content.querySelector('.hand')?.classList.add('deal');
  if (events.length) sound(events.at(-1).kind);
}
let fetching=false;
async function refresh(force=false) {
  if (fetching || (pending && !force)) return;
  fetching=true;
  try {
    const seat=session;
    if (seat) {
      const value=await request('/'+seat.room+'/state'+(state?'?since='+state.version:''),undefined,seat);
      if (session===seat) accept(value);
    } else {
      const {rooms}=await request('',undefined,null);
      if (!session) buildLobby(rooms);
    }
  } catch (error) {
    if (session && error.message.includes('座位已失效')) {
      try { sessionStorage.removeItem('dorm-cards:'+session.room); } catch (_) {}
      session = state = null;
      by('chat').hidden = true;
      notice('座位已失效，请重新加入');
      setTimeout(() => run(refresh), 100);
    } else throw error;
  } finally { fetching=false; }
}
by('chat').addEventListener('submit',event => {
  event.preventDefault();
  if (pending || !by('message').value.trim()) return;
  run(async () => {
    const message=by('message');
    await act('chat',{text:message.value.trim()});
    message.value='';
  });
});
run(async () => {
  if (codePattern.test(queryRoom)) {
    let token;
    try { token=sessionStorage.getItem('dorm-cards:'+queryRoom); } catch (_) {}
    if (token) {
      session={room:queryRoom,token};
      try { await refresh(); } catch (_) { session=null; }
    }
    if (!session) {
      await refresh();
      chooseIdentity(async name => enter(await request('/'+queryRoom+'/join',{name},null)));
    }
  } else await refresh();
});
setInterval(() => { if (session || !dialog.open) refresh().catch(() => {
  if (session) notice('连接中断，正在重试…');
}); }, 900);
