'use strict';
const by = id => document.getElementById(id);
const content = by('content');
const dialog = by('dialog');
const chat = by('chat');
const message = by('message');
const codePattern = /^[2-9A-HJ-NP-Z]{7}$/;
const queryRoom = new URL(location.href).searchParams.get('room')?.toUpperCase();
const modes = {classic:'经典',wild:'癞子',doubleWild:'天地癞子'};
let session = null;
let state = null;
let selected = new Set();
let hints = null;
let selectionRevision = 0;
let loadingHints = false;
let checkingPlay = false;
let selectionCheck = null;
let selectionTimer;
let hintCursor = 0;
let preferred = null;
let appliedAiHintId = null;
let currentEvents = 0;
let currentChat = 0;
let unreadChat = 0;
let pending = false;
let noticeTimer;
let finalPlayTimer = null;
const finalPlayDuration = 1800;
let muted = false;
let cheatsPanel = null;
let connectionLost = false;
let lobbyStamp = null;
let dialogBackdropArmed = false;
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

const MIN_SCALE = 0.75;
const MAX_SCALE = 1.5;
const SCALE_STEP = 0.05;
const scaleButtons = new Set();
function clampScale(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return 1;
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, Math.round(numeric * 20) / 20));
}
let webScale = (() => {
  try { return clampScale(localStorage.getItem('dorm-web-scale') || 1); }
  catch (_) { return 1; }
})();
function syncScaleControls() {
  const pct = Math.round(webScale * 100) + '%';
  for (const label of scaleButtons) label.textContent = pct;
}
function applyWebScale(next, persist = true) {
  webScale = clampScale(next);
  document.documentElement.style.setProperty('--ui-scale', String(webScale));
  const scaled = Math.abs(webScale - 1) > 0.001 ? 'true' : 'false';
  document.documentElement.dataset.scaled = scaled;
  document.body.dataset.scaled = scaled;
  if (persist) {
    try { localStorage.setItem('dorm-web-scale', webScale.toFixed(2)); } catch (_) {}
  }
  syncScaleControls();
  board?.handSurface?.layout();
  requestAnimationFrame(() => board?.handSurface?.layout());
}
function scaleControls() {
  const label = button(Math.round(webScale * 100) + '%', () => applyWebScale(1));
  label.title = '重置为 100% (Ctrl 0)';
  scaleButtons.add(label);
  return el('div', {class:'scale-group', role:'group', 'aria-label':'界面缩放'},
    button('A-', () => applyWebScale(webScale - SCALE_STEP), {label:'缩小界面'}),
    label,
    button('A+', () => applyWebScale(webScale + SCALE_STEP), {label:'放大界面'}));
}
applyWebScale(webScale, false);

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
  if (!response.ok) {
    const error = new Error(result.error || '无法连接牌桌');
    error.status = response.status;
    throw error;
  }
  return result;
}
function openDialog(title, ...parts) {
  delete dialog.dataset.playChoice;
  delete dialog.dataset.lockClose;
  dialog.replaceChildren(el('div',{class:'stack'},el('h2',{},title),parts));
  if (!dialog.open) dialog.showModal();
}
dialog.addEventListener('pointerdown', event => {
  dialogBackdropArmed = event.target === dialog;
});
dialog.addEventListener('click', event => {
  if (dialogBackdropArmed && event.target === dialog && dialog.dataset.lockClose !== 'true') {
    dialog.close();
  }
  dialogBackdropArmed = false;
});
function enter(next) {
  session = next;
  state = null;
  currentEvents = 0;
  currentChat = 0;
  unreadChat = 0;
  message.value = '';
  releaseFan();
  setSelection(new Set());
  hints = null;
  appliedAiHintId = null;
  try { sessionStorage.setItem('dorm-cards:' + next.room, next.token); } catch (_) {}
  const target = new URL(location.href);
  target.searchParams.set('room', next.room);
  history.replaceState(null,'',target);
  return refresh();
}
function chooseIdentity(action) {
  loadAudio();
  const name = el('input',{maxlength:20,placeholder:'可填写昵称'});
  const submitName = () => {dialog.close();return action(name.value.trim());};
  name.addEventListener('keydown', event => {
    if (event.key === 'Enter') {
      event.preventDefault();
      run(submitName);
    }
  });
  openDialog('选择上桌身份',line('牌桌昵称（可选）',name),
    el('div',{class:'actions'},
      button('取消',() => dialog.close()),
      button('跳过，匿名加入',() => {dialog.close();return action('');}),
      button('用昵称继续',submitName,{design:'primary'})));
  dialog.dataset.lockClose = 'true';
  if (matchMedia('(pointer: fine)').matches) name.focus();
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
  const way = select('landlordCall',[['score','叫分'],['call','叫地主']],old.landlordCall ?? 'score');
  const wayRow = line('地主产生方式',way);
  const first = select('firstCaller',[['random','每局随机'],['previousWinner','上局最先出完']],old.firstCaller ?? 'random');
  const rounds = number('matchRounds',old.matchRounds ?? 0,0,30);
  const counter = check('cardCounter','全员记牌器',old.cardCounter ?? false);
  const reserve = check('reserve','给地主底牌',old.bottom > 0);
  const chain = check('chainBombs','连炸（每组张数相同，至少四张）',old.chainBombs ?? (previous === null));
  const rocket = check('rocketBeatsChain','王炸大于连炸',old.rocketBeatsChain ?? (previous !== null));
  const bombOrder = el('small');
  const four = check('fourWithTwo','四带二／四带两对',old.fourWithTwo ?? true);
  const summary = el('p',{class:'muted'});
  const reserveRow = el('div',{class:'stack'},reserve,line('底牌张数',bottom));
  function rule() {
    const hasLandlord = landlord.querySelector('input').checked;
    const hasBottom = hasLandlord && reserve.querySelector('input').checked;
    return {players:Number(players.value),decks:Number(decks.value),discard:Number(discard.value),
      landlord:hasLandlord,bottom:hasBottom ? Number(bottom.value) : 0,mode:mode.value,remainder:remainder.value,
      chainBombs:chain.querySelector('input').checked,rocketBeatsChain:rocket.querySelector('input').checked,
      fourWithTwo:four.querySelector('input').checked,landlordCall:way.value,
      firstCaller:first.value,matchRounds:Number(rounds.value),cardCounter:counter.querySelector('input').checked};
  }
  function counts() {
    const r = rule();
    rocket.querySelector('input').disabled = !r.chainBombs;
    bombOrder.textContent = r.rocketBeatsChain
      ? '王炸优先，其余炸弹按总张数比较'
      : '按总张数比较，王炸相当于 8 张，同等级连炸优先';
    reserveRow.hidden = wayRow.hidden = !r.landlord;
    bottom.disabled = !r.landlord || !reserve.querySelector('input').checked;
    const available = r.decks*54-r.bottom-r.discard;
    summary.textContent = r.players ? '起手每位 '+Math.max(0,Math.floor(available/r.players))+' 张 · 余 '+Math.max(0,available%r.players)+' 张' : '';
  }
  const form = el('form',{class:'stack'},
    line('玩法',mode),el('div',{class:'duo'},line('人数',players),line('副数',decks)),
    chain,el('div',{class:'rule-order'},rocket,bombOrder),four,
    landlord,wayRow,reserveRow,
    el('div',{class:'duo'},line('首个行动的座位',first),line('比赛局数（0 为不限）',rounds)),
    counter,line('随机舍弃张数',discard),line('余牌处理',remainder),summary,
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
  dialog.dataset.lockClose = 'true';
  counts();
}
function buildLobby(rooms) {
  clearBoard();
  const stamp = [queryRoom ?? '', ...rooms.map(r => `${r.room}:${r.players}:${r.capacity}:${r.mode}:${r.host}:${r.landlord}`)].join('|');
  let list = by('lobby-rooms');
  if (!list) {
    lobbyStamp = null;
    const codeInput = el('input',{id:'lobby-code',maxlength:7,placeholder:'输入 7 位房间号','aria-label':'房间号',autocapitalize:'characters',spellcheck:'false'});
    const joinForm = el('form',{class:'lobby-join'},codeInput,el('button',{type:'submit'},'加入房间'));
    joinForm.addEventListener('submit', event => {
      event.preventDefault();
      const code = codeInput.value.trim().toUpperCase();
      if (!codePattern.test(code)) {
        notice('请输入有效的 7 位房间号');
        codeInput.focus();
        return;
      }
      chooseIdentity(async name => enter(await request('/'+code+'/join',{name},null)));
    });
    list = el('div',{id:'lobby-rooms',class:'stack'});
    content.replaceChildren(el('div',{class:'stack'},
      el('div',{class:'lobby-bar'},
        el('div',{class:'actions'},button('创建房间',() => rulesForm(),{design:'primary'}),button('刷新',refresh),scaleControls()),
        joinForm),
      el('h2',{},'局域网房间'),
      list));
  }
  if (lobbyStamp === stamp) return;
  lobbyStamp = stamp;
  const choices = rooms.map(room => el('article',{class:'room'},
    el('div',{},el('h3',{},room.host+'的牌桌'),
      el('small',{},room.players+'/'+room.capacity+' 人 · '+(modes[room.mode] ?? '斗地主')+(room.landlord===false?' · 无地主':' · 地主局'))),
    button('加入',() => chooseIdentity(async name => enter(await request('/'+room.room+'/join',{name},null))),{design:'primary'})));
  if (codePattern.test(queryRoom) && !rooms.some(item => item.room === queryRoom)) {
    choices.unshift(el('article',{class:'room'},el('div',{},el('h3',{},'邀请房间 '+queryRoom)),
      button('尝试加入',() => chooseIdentity(async name => enter(await request('/'+queryRoom+'/join',{name},null))))));
  }
  list.replaceChildren(...(choices.length ? choices : [el('p',{class:'muted'},'还没有可加入的牌桌，可以创建房间或输入房间号加入。')]));
}
function face(card) {
  const rank = card.rank ?? rankOf(card.id);
  const suit = suitOf(card.id);
  return el('span',{class:'mini-face'+(suit==='♦'||suit==='♥'||rank===17?' red':'')},
    el('strong',{},rankName(rank)),suit ? el('span',{},suit) : null);
}
const playerName = id => state?.people.find(person => person.id===id)?.name ?? '';
const gestureActive = () => Boolean(board?.hand.gesture);

const moveLabels = {lead:'先出',beat:'管上',pass:'不要'};

function turnMoves(s) {
  const moves = new Map(s.people.map(player=>[player.id,player.move]));
  if (s.people.some(player=>'move' in player) || !s.last || s.leader==null) return moves;
  const play = s.events.findLast(event=>event.from===s.leader && ['play','bomb','rocket'].includes(event.kind));
  if (!play) return moves;
  moves.set(s.leader,'lead');
  for (const event of s.events) {
    if (event.kind==='pass' && event.id>play.id) moves.set(event.from,'pass');
  }
  return moves;
}

function moveTag(move) {
  return moveLabels[move] ? el('span',{class:'move-tag move-'+move},moveLabels[move]) : null;
}

function seatView(player, move) {
  if (!player) return el('div',{class:'seat vacant'},'空座');
  const role = player.id===state.landlord ? '地主' : '';
  const called = state.phase==='bidding' && player.called != null
    ? (player.called === 0 ? '不叫' : state.rules.landlordCall==='call' ? '叫地主' : player.called+' 分') : '';
  const automatic = player.autoplay === true;
  const autoLabel = player.botMode === 'api' && !state.apiSuspended ? 'API 托管' : '本地托管';
  const seat = button('',()=>{
    if (state.debug?.gui) return showCheats(player.id);
    if (state.debug?.hands?.[player.id]) return showDebugHand(player.id,player.name);
    openDialog(player.name,
      button('🍅 丢番茄',async()=>{await act('tomato',{target:player.id});dialog.close();}),
      button('关闭',()=>dialog.close()));
  },{design:'seat'+(player.id===state.turn?' turn':'')});
  seat.dataset.seat = player.id;
  if (moveLabels[move]) seat.dataset.move = move;
  seat.title = [player.name,role,called,moveLabels[move],automatic?autoLabel+'中':'',player.cards+' 张'].filter(Boolean).join(' · ');
  seat.append(el('span',{class:'seat-avatar','aria-hidden':'true'},player.bot?(player.botMode==='api'?'AI':'机'):Array.from(player.name)[0]),
    el('span',{class:'seat-text'},el('b',{},player.name),
      el('span',{class:'seat-meta'},role ? el('span',{class:'landlord-badge'},role) :
        called ? el('small',{},called) : null,moveTag(move))),
    el('strong',{class:'seat-count','aria-label': (automatic?autoLabel+'中，':'')+player.cards+' 张'},
      automatic ? el('span',{class:'seat-auto',title:autoLabel},'机 ') : null,player.cards));
  return seat;
}

function opponentSeats(s) {
  const me = Math.max(0,s.people.findIndex(person=>person.id===s.you));
  const others = [];
  for (let step=1;step<s.people.length;step++) others.push(s.people[(me+step)%s.people.length]);
  while (others.length<s.rules.players-1) others.push(null);
  return others.reverse();
}

function ownAutoplay() {
  return state?.people.find(player => player.id===state.you)?.autoplay === true;
}
function ownAutoMode() {
  return state?.people.find(player => player.id===state.you)?.botMode ?? 'local';
}
function chooseBotMode(title, localLabel, apiLabel, unavailableText, onChosen) {
  const apiReady = state?.apiAvailable === true;
  openDialog(title,
    el('div',{class:'stack'},
      button(localLabel,async()=>{dialog.close();await onChosen('local');}),
      button(apiLabel,async()=>{dialog.close();await onChosen('api');},{disabled:!apiReady}),
      el('small',{class:'muted'},apiReady
        ? '模型单次最多等 '+(state.apiWaitSeconds ?? 45)+' 秒，同局 '+(state.apiTimeoutLimit ?? 3)+' 次超时后本地接管'
        : unavailableText)),
    el('div',{class:'actions'},button('取消',()=>dialog.close())));
}
function canSelectCards() {
  return session && state?.phase==='playing' && !pending && !ownAutoplay();
}
function sameHand(a,b) {
  return a!=null && b!=null && a.room===b.room && a.you===b.you &&
    a.hand.length===b.hand.length && a.hand.every((id,index)=>id===b.hand[index]);
}
function setSelection(cards, pattern=null) {
  selected = cards;
  preferred = pattern;
  selectionRevision++;
  clearTimeout(selectionTimer);
  selectionCheck = null;
  if (pattern===null) hintCursor = 0;
}
function changeSelection(cards) {
  setSelection(cards);
  renderRoom();
}
function releaseFan() {
  board?.hand.cancel();
}

function showCards(title,cards,editable=false) {
  const list = el('div',{class:'inspect-cards'});
  for (const card of cards) {
    if (!editable) {
      list.append(face(card));
      continue;
    }
    const key = button('',()=>{
      if (!canSelectCards() || !state.hand.includes(card.id)) return;
      const next = new Set(selected);
      if (!next.delete(card.id)) next.add(card.id);
      changeSelection(next);
      key.setAttribute('aria-pressed',String(next.has(card.id)));
    },{design:'inspect-card'});
    key.setAttribute('aria-label',rankName(rankOf(card.id))+suitOf(card.id));
    key.setAttribute('aria-pressed',String(selected.has(card.id)));
    key.append(face(card));
    list.append(key);
  }
  openDialog(title,list,button('完成',()=>dialog.close(),{design:'primary'}));
}

function showBottom() {
  const bottom = state.bottom.map(id=>({id}));
  if (bottom.length) showCards('地主底牌',bottom);
  else openDialog('地主底牌',el('p',{},'底牌 '+state.rules.bottom+' 张 · 叫分后揭晓'),button('关闭',()=>dialog.close()));
}
function chatSpeaker(event) {
  const name = event.sender || playerName(event.from) || '玩家';
  return event.replyTo == null || event.from == null ? name : name+'（AI）';
}
function updateChatBadge() {
  if (!board) return;
  board.chatBadge.hidden = unreadChat===0;
  board.chatBadge.textContent = unreadChat>99?'99+':String(unreadChat);
  board.chatButton.setAttribute('aria-label',unreadChat?'牌桌消息，'+unreadChat+' 条未读':'牌桌消息');
}
function chatMessages(value) {
  return value.chat?.messages ?? value.events.filter(event=>event.kind==='chat');
}
function chatOpen() {
  return Boolean(dialog.open && board?.chatPanel?.root.isConnected);
}
function updateChat() {
  if (!chatOpen()) return;
  const panel = board.chatPanel;
  const info = state.chat;
  const messages = chatMessages(state);
  const byId = new Map(messages.map(item=>[item.id,item]));
  const items = panel.system ? state.events.filter(event=>event.kind!=='chat') : messages;
  const stamp = (panel.system?'system':'chat')+':'+items.map(item=>item.id+(item.aiSkipped?'!':'')).join(',');
  if (stamp !== panel.stamp) {
    const list = panel.feed;
    const nearBottom = panel.stamp == null || list.scrollHeight-list.scrollTop-list.clientHeight < 36;
    panel.stamp = stamp;
    list.replaceChildren(...items.map(event=>{
      if (panel.system) return el('p',{class:'chat-system-line'},event.text);
      const ai = event.replyTo != null;
      const mine = event.from === state.you;
      const quote = byId.get(event.replyTo);
      const time = event.time == null ? '' : new Date(event.time)
        .toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
      return el('article',{class:'chat-entry '+(mine?'mine':ai?'ai':'guest')},
        el('div',{class:'chat-author'},ai?'✦ ':null,mine?'我':chatSpeaker(event),time?el('time',{},time):null),
        el('div',{class:'chat-bubble'},quote?el('small',{class:'chat-quote'},'↳ '+quote.text):null,
          el('div',{},event.text),event.aiSkipped?el('small',{class:'chat-queue-note'},event.aiSkipped):null));
    }));
    if (!items.length) list.append(el('p',{class:'chat-empty'},panel.system?'暂无系统记录':'还没有消息，打个招呼吧'));
    if (nearBottom) list.scrollTop = list.scrollHeight;
  }
  panel.chatTab.setAttribute('aria-pressed',String(!panel.system));
  panel.chatTab.textContent = '聊天'+(panel.system && unreadChat ? ' · '+unreadChat : '');
  panel.systemTab.setAttribute('aria-pressed',String(panel.system));
  chat.hidden = panel.system;
  chat.querySelector('button').disabled = pending || !message.value.trim();
  panel.aiTools.hidden = panel.system || !info;
  panel.aiToggle.hidden = state.host !== state.you;
  panel.aiToggle.disabled = pending;
  panel.aiToggle.setAttribute('aria-pressed',String(info?.enabled === true));
  panel.aiToggle.textContent = info?.enabled ? '关闭' : '开启';
  panel.aiLabel.textContent = !info?.available ? 'AI 回复 · 房主需启用电脑 API' :
    info.enabled ? 'AI 回复已开启' : 'AI 回复已关闭';
  const status = info?.status;
  panel.status.hidden = panel.system || !status;
  panel.root.classList.toggle('chat-thinking',status?.pending===true);
  panel.statusText.textContent = status?.pending
    ? 'AI 正在回复…'+(info.queued ? ' · '+info.queued+' 条排队' : '')
    : status?.error ?? '';
  const source = byId.get(status?.source);
  panel.retry.hidden = !status?.error || !info.available || !info.enabled ||
    (state.you !== state.host && source?.from !== state.you);
  panel.retry.disabled = pending;
}
async function actChat(action, data) {
  const panel = board?.chatPanel;
  if (!panel || pending || !session) return false;
  panel.error.hidden = true;
  try {
    const task = act(action,data);
    updateChat();
    await task;
    return true;
  } catch (error) {
    panel.error.textContent = error.message || '操作失败';
    panel.error.hidden = false;
    return false;
  } finally {
    updateChat();
  }
}
function showChat() {
  const panel = {system:false,stamp:null};
  const selectTab = system=>{
    if (panel.system === system) return;
    panel.system = system;
    panel.stamp = null;
    if (!system) unreadChat = 0;
    updateChatBadge();
    updateChat();
  };
  panel.chatTab = button('聊天',()=>selectTab(false));
  panel.systemTab = button('系统',()=>selectTab(true));
  panel.feed = el('section',{class:'message-history','aria-label':'消息记录',tabindex:0});
  panel.aiLabel = el('span',{},'AI 回复');
  panel.aiToggle = button('开启',()=>actChat('chatAi',{enabled:!state.chat.enabled}));
  panel.aiTools = el('div',{class:'chat-ai-tools'},panel.aiLabel,panel.aiToggle);
  panel.statusText = el('span',{role:'status'});
  panel.retry = button('重试',()=>actChat('retryChatAi',{source:state.chat.status.source}));
  panel.status = el('div',{class:'chat-status'},panel.statusText,panel.retry);
  panel.error = el('p',{class:'chat-error',role:'alert',hidden:true});
  panel.root = el('div',{class:'chat-panel'},
    el('div',{class:'chat-tabs',role:'group','aria-label':'消息类型'},panel.chatTab,panel.systemTab),
    panel.aiTools,panel.feed,panel.status,panel.error,chat);
  board.chatPanel = panel;
  unreadChat = 0;
  updateChatBadge();
  openDialog('牌桌消息',panel.root,button('关闭',()=>dialog.close()));
  updateChat();
  panel.feed.scrollTop = panel.feed.scrollHeight;
  if (matchMedia('(pointer: fine)').matches) message.focus();
}
function settingsMenu() {
  const extras = [];
  if (state.debug) {
    extras.push(button('调试',showDebug));
    if (state.debug.hands?.[state.you]) extras.push(button('查看自己的手牌',()=>showDebugHand(state.you,'自己')));
  }
  if (state.you===state.host && ['playing','bidding'].includes(state.phase)) {
    extras.push(button('结束牌局',()=>openDialog('结束当前牌局？',
      button('取消',()=>dialog.close()),button('结束牌局',async()=>{await act('abort');dialog.close();}))));
  }
  const last = state.last ?? state.previousTrick?.play;
  if (last) extras.push(button('查看上一手',()=>showCards(last.label,last.cards)));
  if (state.hand.length) extras.push(button('展开手牌',()=>showCards('我的手牌',state.hand.map(id=>({id})),canSelectCards())));
  extras.push(el('div',{class:'menu-scale-row'},el('span',{},'界面缩放'),scaleControls()));
  openDialog('牌桌菜单',extras,
    button(muted?'打开音效':'关闭音效',()=>{by('audio').click();dialog.close();}),
    button('离开房间',leave),button('返回牌桌',()=>dialog.close(),{design:'primary'}));
}
function showDebug() {
  const debug = state?.debug;
  if (!debug) return;
  const input = el('input',{type:'text',maxlength:500,'aria-label':'调试指令',autocapitalize:'none',spellcheck:'false'});
  const feedback = el('p',{role:'status',hidden:true});
  const submit = button('执行',async()=>{
    const command = input.value.trim();
    if (!command || pending || !state?.debug) return;
    submit.disabled = true;
    feedback.hidden = true;
    try {
      await act('debug',{command,deal:state.debug.deal});
      input.value = '';
      feedback.textContent = '已执行';
    }catch(error){
      feedback.textContent = error.message;
    }finally{
      feedback.hidden = false;
      submit.disabled = false;
    }
  },{design:'primary'});
  input.addEventListener('keydown',event=>{
    if (event.key==='Enter') { event.preventDefault(); submit.click(); }
  });
  openDialog('调试',input,feedback,
    el('div',{class:'actions'},button('关闭',()=>dialog.close()),submit));
  input.focus();
}

function showCheats(initialSeat=null) {
  if (!state?.debug?.gui || pending) return;
  const seats = el('div',{class:'actions'});
  const name = el('b',{});
  const hand = el('div',{class:'inspect-cards cheats-hand'});
  const inspect = check('inspect','保留座位查看权限',false);
  const force = check('force','强制出牌',false);
  const inspectInput = inspect.querySelector('input');
  const forceInput = force.querySelector('input');
  const input = el('input',{maxlength:500,placeholder:'45245234','aria-label':'牌面'});
  const feedback = el('small',{role:'status',hidden:true});
  const panel = {
    seats,name,hand,inspect,force,inspectInput,forceInput,input,feedback,
    selected:new Set(),seat:null,deal:null,stamp:null,cardStamp:null,busy:false,
  };
  async function send(action,data) {
    if (!state?.debug?.gui || pending || panel.busy) return false;
    panel.feedback.hidden = true;
    panel.busy = true;
    refreshCheats();
    try {
      await act(action,{deal:state.debug.deal,...data});
      return true;
    }catch(error){
      panel.feedback.textContent = error.message;
      panel.feedback.hidden = false;
      return false;
    }finally{
      panel.busy = false;
      refreshCheats();
    }
  }
  const withSeat = (op,fields={}) => send('debugGui',{op,seat:panel.seat,...fields});
  async function submit(op) {
    const cards = input.value.trim();
    if (cards && await withSeat(op,{cards})) input.value = '';
  }
  inspectInput.addEventListener('change',()=>withSeat('inspect',{enabled:inspectInput.checked}));
  forceInput.addEventListener('change',()=>withSeat('force',{enabled:forceInput.checked}));
  input.addEventListener('keydown',event=>{
    if (event.key==='Enter') { event.preventDefault(); submit('add'); }
  });
  panel.remove = button('',async()=>{
    if (await send('debugRemove',{seat:panel.seat,cards:[...panel.selected]})) {
      panel.selected.clear();
      refreshCheats();
    }
  });
  panel.add = button('添加牌',()=>submit('add'),{design:'primary'});
  panel.play = button('指定出牌',()=>submit('play'));
  panel.tomato = button('丢番茄',()=>send('tomato',{target:panel.seat}));
  panel.hide = button('隐藏 Cheats',()=>send('debugGui',{op:'hide'}));
  panel.palette = el('div',{class:'actions cheats-palette'},
    ['3','4','5','6','7','8','9','10','J','Q','K','A','2','B','R'].map(rank=>
      button(rank==='B'?'小王':rank==='R'?'大王':rank,()=>withSeat('add',{cards:rank}))));
  panel.editor = el('div',{class:'stack',hidden:true},inspect,force,name,hand,panel.remove,
    panel.palette,input,el('div',{class:'actions'},panel.add,panel.play,panel.tomato));
  panel.root = el('div',{class:'stack'},seats,panel.editor,feedback,
    el('div',{class:'actions'},panel.hide,button('关闭',()=>dialog.close())));
  panel.select = seat => send('debugGui',{op:'select',seat});
  cheatsPanel = panel;
  openDialog('Cheats',panel.root);
  refreshCheats();
  if (initialSeat!=null) panel.select(initialSeat);
}

function refreshCheats() {
  const panel = cheatsPanel;
  if (!panel) return;
  if (!dialog.open || !panel.root.isConnected) {
    cheatsPanel = null;
    return;
  }
  const debug = state?.debug;
  if (!debug?.gui) {
    dialog.close();
    cheatsPanel = null;
    return;
  }
  const editor = debug.editor;
  const seat = editor?.seat ?? null;
  const locked = panel.busy || pending;
  if (panel.seat!==seat || panel.deal!==debug.deal) {
    panel.seat = seat;
    panel.deal = debug.deal;
    panel.selected.clear();
    panel.input.value = '';
  }
  const seatStamp = [state.version,locked].join('/');
  if (panel.stamp!==seatStamp) {
    panel.stamp = seatStamp;
    panel.seats.replaceChildren(...['A','B','C','D','E','F','G','H']
      .filter(code=>debug.seats[code]!=null)
      .map(code=>{
        const id = debug.seats[code];
        const tab = button(code+' · '+(id===state.you?'自己':playerName(id)),
          ()=>panel.select(id),{design:id===seat?'primary':undefined,disabled:locked});
        tab.setAttribute('aria-pressed',String(id===seat));
        return tab;
      }));
  }
  panel.hide.disabled = locked;
  panel.editor.hidden = !editor;
  if (!editor) return;
  const cards = editor.cards;
  panel.selected = new Set([...panel.selected].filter(id=>cards.includes(id)));
  const active = ['playing','bidding'].includes(state.phase);
  const own = seat===state.you;
  const canPlay = own && state.phase==='playing' && state.turn===seat && !ownAutoplay();
  const cardStamp = [seat,debug.deal,...cards].join('/');
  if (panel.cardStamp!==cardStamp) {
    panel.cardStamp = cardStamp;
    panel.hand.replaceChildren(...cards.map(id=>debugCardButton(id,panel.selected.has(id),()=>{
      if (!panel.selected.delete(id)) panel.selected.add(id);
      refreshCheats();
    })));
  }
  for (const [index,card] of Array.from(panel.hand.children).entries()) {
    card.disabled = !active || locked;
    card.setAttribute('aria-pressed',String(panel.selected.has(cards[index])));
  }
  panel.name.textContent = playerName(seat)+' · '+cards.length+' 张';
  panel.inspectInput.checked = Boolean(debug.hands?.[seat]);
  panel.inspectInput.disabled = locked;
  panel.force.hidden = !own;
  panel.forceInput.checked = Boolean(debug.forceOut);
  panel.forceInput.disabled = locked;
  updateDeleteButton(panel.remove,active,panel.selected.size,cards.length,locked);
  panel.palette.hidden = panel.input.hidden = panel.add.hidden = !active;
  panel.add.disabled = locked;
  panel.input.disabled = locked;
  for (const rank of panel.palette.children) rank.disabled = locked;
  panel.play.hidden = !canPlay;
  panel.play.disabled = locked;
  panel.tomato.hidden = !active || own;
  panel.tomato.disabled = locked;
}

function debugCardButton(id,selected,onClick) {
  const card = button('',onClick,{design:'inspect-card debug-card'});
  card.setAttribute('aria-pressed',String(selected));
  card.setAttribute('aria-label',rankName(rankOf(id))+suitOf(id));
  card.append(face({id}));
  return card;
}
function updateDeleteButton(button,active,count,total,busy) {
  button.hidden = !active || !count;
  button.disabled = busy || count>=total;
  button.textContent = '删除 '+count+' 张牌';
}
function showDebugHand(seat,name) {
  const debug = state?.debug;
  const ids = debug?.hands?.[seat];
  if (!ids) return;
  const selected = new Set();
  const active = ['bidding','playing'].includes(state.phase);
  const feedback = el('p',{role:'status'});
  const remove = button('',async()=>{
    if (!selected.size || pending || !state?.debug) return;
    remove.disabled = true;
    try {
      await act('debugRemove',{seat,cards:[...selected],deal:debug.deal});
      showDebugHand(seat,name);
    }catch(error){
      feedback.textContent = error.message;
      remove.disabled = false;
    }
  });
  remove.hidden = true;
  const list = el('div',{class:'inspect-cards'});
  for (const id of ids) {
    const card = debugCardButton(id,false,()=>{
      if (!selected.delete(id)) selected.add(id);
      card.setAttribute('aria-pressed',String(selected.has(id)));
      updateDeleteButton(remove,['bidding','playing'].includes(state?.phase),selected.size,ids.length,pending);
    });
    card.disabled = !active;
    list.append(card);
  }
  openDialog(name+' 的手牌',ids.length?list:el('p',{},'当前没有可查看的手牌'),feedback,
    el('div',{class:'actions'},button('关闭',()=>dialog.close()),remove));
}
async function toggleFullscreen() {
  if (document.fullscreenElement) {
    await document.exitFullscreen();
    return;
  }
  try {
    await document.documentElement.requestFullscreen();
    ownedFullscreen = true;
  } catch (_) {
    notice('浏览器保留了工具栏，牌桌仍可横屏操作');
    return;
  }
  if (matchMedia('(pointer: coarse)').matches) {
    try { await screen.orientation?.lock?.('landscape'); } catch (_) { /* CSS keeps the table horizontal. */ }
  }
}

let board = null;
let ownedFullscreen = false;
function clearBoard() {
  unreadChat = 0;
  clearTimeout(finalPlayTimer);
  finalPlayTimer = null;
  if (!board) return;
  clearTimeout(board.aiTimer);
  board.hand.dispose();
  for (const lane of board.lanes.values()) lane.cards.dispose();
  board = null;
  content.replaceChildren();
  document.body.classList.remove('at-table');
  if (ownedFullscreen && document.fullscreenElement) document.exitFullscreen().catch(()=>{});
  ownedFullscreen = false;
}

function mountBoard() {
  const roomText = el('div',{class:'table-identity'});
  const bottom = button('',showBottom,{design:'bottom-preview',title:'查看地主底牌'});
  const fullscreen = button('全屏',toggleFullscreen,{title:'横屏全屏'});
  fullscreen.hidden = !document.fullscreenEnabled;
  const seats = el('div',{class:'opponents','aria-label':'其他玩家'});
  const counter = el('div',{class:'rank-counter',title:'未见牌，含未知的底牌和弃牌',hidden:true});
  const cheats = button('Cheats',()=>showCheats(),{design:'cheats-entry'});
  cheats.hidden = true;
  const autoButton = button('托管',() => ownAutoplay()
    ? act('autoplay',{enabled:false})
    : chooseBotMode('选择托管模式','本地托管（内置规则）','API 托管（模型出牌）','需房主先启用电脑 API',mode=>act('autoplay',{enabled:true,mode})));
  const summary = el('div',{class:'settlement',hidden:true});
  const advice = button('',showAiAdvice,{design:'ai-advice'});
  advice.hidden = true;
  const status = el('p',{class:'turn-status',role:'status'});
  const wild = el('span',{class:'wild-status'});
  const spots = el('div',{class:'play-spots'});
  const ownMove = el('span',{class:'own-move'});
  const aiStage = el('span',{role:'status'});
  const aiTime = el('span');
  const aiCancel = button('取消提示',()=>act(state?.aiHint?.pending?'cancelAiHint':'skipBotWait'));
  const aiWait = el('div',{class:'ai-progress',hidden:true},aiStage,aiTime,aiCancel);
  const controls = el('div',{class:'play-controls'});
  const passButton = button('不出',() => act('pass',{},state?.turnVersion));
  const hintButton = button('提示',hint);
  const aiButton = button('AI 提示',()=>act('aiHint',{},state?.turnVersion));
  const playButton = button('出牌',choosePlay,{design:'primary'});
  const count = el('span',{class:'own-count'});
  const ownRole = el('span',{class:'landlord-badge',hidden:true},'地主');
  const countSelected = el('span',{class:'selection-count','aria-live':'polite'});
  const clear = button('清空',()=>changeSelection(new Set()),{design:'text-action'});
  const expand = button('展开手牌',()=>showCards('我的手牌',state.hand.map(id=>({id})),canSelectCards()),
    {design:'text-action'});
  expand.hidden = true;
  const hand = el('div',{class:'hand-canvas',role:'group','aria-label':'我的手牌',title:'点击或拖选出牌，右键取消全选'});
  hand.addEventListener('contextmenu', event => {
    if (!canSelectCards() || !selected.size) return;
    event.preventDefault();
    changeSelection(new Set());
  });
  const chatButton = button('消息',showChat,{title:'牌桌消息',design:'chat-button'});
  const chatBadge = el('span',{class:'chat-unread',hidden:true,'aria-hidden':'true'});
  chatButton.append(chatBadge);
  const surface = el('section',{class:'card-stage','aria-label':'斗地主牌桌'},
    el('div',{class:'table-top'},
      el('div',{class:'table-head'},roomText,el('div',{class:'bottom-slot'},bottom),
        el('div',{class:'head-tools'},autoButton,chatButton,button('分享',share),fullscreen,cheats,button('更多',settingsMenu))),
      counter),
    seats,
    el('div',{class:'trick-zone'},spots,summary),
    el('div',{class:'action-row'},el('div',{class:'action-status'},status,wild),controls),
    aiWait,
    el('div',{class:'hand-line'},count,ownRole,ownMove,countSelected,clear,expand,advice),
    hand);
  document.body.classList.add('at-table');
  content.replaceChildren(surface);
  return {surface,roomText,bottom,seats,status,wild,spots,counter,autoButton,cheats,summary,advice,controls,
    passButton,hintButton,aiButton,playButton,aiWait,aiStage,aiTime,aiCancel,aiDeadline:null,
    count,ownRole,ownMove,countSelected,clear,expand,chatButton,chatBadge,chatPanel:null,
    hand:new CardSurface(hand,{onSelection:changeSelection,onDense:dense=>{expand.hidden=!dense;}}),
    lanes:new Map(),version:null};
}

function renderTrick(s, opponents, moves) {
  const previous = s.last ? null : s.previousTrick;
  const played = s.last ?? previous?.play;
  const actor = s.leader ?? previous?.leader;
  const entries = new Map((s.last && finalPlayTimer === null ? s.tablePlays ?? [] : [])
    .map(item => [item.seat, item.play]));
  if (played && actor != null) entries.set(actor, played);
  if (s.turn!==s.you) entries.delete(s.turn);
  for (const [seat, lane] of board.lanes) {
    if (!entries.has(seat)) {
      lane.cards.dispose();
      lane.area.remove();
      board.lanes.delete(seat);
    }
  }
  const others = [...entries.keys()].filter(seat => seat !== s.you);
  const split = entries.has(s.you) && others.length > 0;
  board.spots.dataset.split = String(split);
  board.spots.dataset.busy = String(opponents.length > 3);
  for (const [seat, play] of entries) {
    let lane = board.lanes.get(seat);
    if (!lane) {
      const heading = el('div',{class:'last-play'});
      const canvas = el('div',{class:'played-canvas'});
      const area = el('div',{class:'play-area'},heading,canvas);
      board.spots.append(area);
      lane = {area,heading,cards:new CardSurface(canvas), stamp:null};
      board.lanes.set(seat,lane);
    }
    const mine = seat === s.you;
    const index = opponents.findIndex(player => player?.id === seat);
    const anchor = mine || index < 0 || opponents.length===1 ? .5
      : opponents.length===2 ? (index===0?.16:.84) : (index+.5)/opponents.length;
    lane.area.dataset.owner = mine ? 'self' : 'opponent';
    lane.area.dataset.current = String(seat === actor);
    lane.area.dataset.bomb = String(Boolean(play.bomb));
    lane.area.style.setProperty('--play-x',anchor*100+'%');
    lane.area.style.setProperty('--play-width',Math.min(580,Math.max(145,106+play.cards.length*19))+'px');
    lane.area.style.setProperty('--lane-limit',mine || others.length < 2 ? '100%' : (100 / opponents.length)+'% - 6px');
    const tag = previous ? el('span',{class:'move-tag move-previous'},'上轮') : moveTag(moves.get(seat));
    lane.heading.replaceChildren(el('strong',{},mine?'我的出牌':playerName(seat)+' 出牌'),
      ...[tag].filter(Boolean),el('span',{},play.label));
    const stamp = [play.key,...play.cards.map(card=>card.id)].join('/');
    if (stamp !== lane.stamp && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
      if (play.bomb && seat === actor && !previous) {
        const splash = el('span',{class:'power-banner','aria-hidden':'true'},play.label+' ×'+(play.bombMultiplier ?? 2));
        board.spots.append(splash);
        splash.animate([{opacity:0,scale:.9},{opacity:1,scale:1,offset:.15},
          {opacity:1,scale:1.02,offset:.65},{opacity:0,scale:1.10}],{duration:720}).finished
          .then(()=>splash.remove(),()=>splash.remove());
      }
      lane.area.animate([{transform:'translateY('+(mine?7:-7)+'px)'},
        {transform:'translateY(0)'}],{duration:195,easing:'cubic-bezier(.2,.8,.2,1)'});
    }
    lane.stamp = stamp;
    lane.cards.update(play.cards);
  }
}

function showAiAdvice() {
  const hint = state?.aiHint;
  if (!hint?.reason) return;
  const play = hint.play;
  const buttons = [];
  if (play) buttons.push(button('选中建议的牌',() => {
    if (state?.turnVersion !== hint.turn || state.aiHint?.id !== hint.id || ownAutoplay()) return;
    setSelection(new Set(play.cards.map(card => card.id)),play.key);
    renderRoom();
    dialog.close();
  },{design:'primary'}));
  buttons.push(button('关闭',()=>dialog.close()));
  const action = play ? '出牌 · '+play.label : '不出';
  const counts = new Map();
  for (const card of play?.cards ?? []) {
    counts.set(card.rank,(counts.get(card.rank) ?? 0)+1);
  }
  const ranks = [...counts.entries()].sort(([a],[b])=>a-b)
    .map(([rank,count])=>(count===1?'':count+'张')+rankName(rank)).join(' ');
  openDialog('AI 出牌建议',
    el('p',{},el('strong',{},'建议动作　'),action),
    play ? el('p',{},el('strong',{},'出牌牌面　'),ranks) : null,
    el('p',{},el('strong',{},'判断理由　'),hint.reason),
    el('div',{class:'actions'},buttons));
}

function renderSettlement(s) {
  const summary = finalPlayTimer === null ? s.settlement : null;
  board.summary.hidden = !summary;
  board.spots.hidden = Boolean(summary);
  if (!summary) return;
  const rows = new Map(summary.players.map(player => [player.seat,player]));
  const signed = value => Number(value)>0 ? '+'+value : String(value);
  board.summary.replaceChildren(
    el('h3',{},s.matchComplete ? '全场结算' : '第 '+s.round+' 局结算'),
    el('small',{},'底分 '+summary.base+' · 炸弹 '+summary.bombs+' · '+summary.multiplier+' 倍'+(summary.spring?' · '+summary.spring:'')),
    ...(s.standings ?? summary.players).map(rank => {
      const player = rows.get(rank.seat);
      if (!player) return null;
      return el('div',{class:'settlement-row'},
        el('div',{class:'settlement-head'},
          el('b',{},player.name+(player.seat===s.you?'（你）':'')),
          player.seat===s.landlord ? el('span',{class:'landlord-badge'},'地主') : null,
          el('span',{},'本局 '+signed(player.delta)),el('strong',{},'总分 '+signed(player.total))),
        player.cards.length ? el('div',{class:'remaining-cards'},player.cards.map(id=>face({id})))
          : el('small',{},'已出完'));
    }));
}

function renderRoom() {
  if (!state) return;
  board ??= mountBoard();
  const s = state;
  const own = s.you===s.turn;
  const host = s.you===s.host;
  const bidding = s.phase==='bidding';
  const playing = s.phase==='playing';
  const active = bidding || playing;
  const activeRuleNames = [modes[s.rules.mode],s.rules.decks+' 副'];
  activeRuleNames.push(s.rules.chainBombs ? '连炸开' : '连炸关');
  const autoplay = ownAutoplay();
  const autoMode = ownAutoMode();
  const autoLabel = autoMode === 'api' && !s.apiSuspended ? 'API 托管' : '本地托管';
  const preview = own && playing && !autoplay && selected.size ? activeSelectionCheck() : null;
  board.autoButton.hidden = !active && !autoplay;
  board.autoButton.disabled = pending;
  board.cheats.hidden = s.debug?.gui !== true;
  board.cheats.disabled = pending;
  board.autoButton.textContent = autoplay ? '取消'+autoLabel : '托管';
  board.autoButton.setAttribute('aria-pressed',String(autoplay));
  const controls = [];
  if (host && !active && finalPlayTimer === null) {
    controls.push(button(s.phase==='finished'?(s.matchComplete?'开始新比赛':'下一局'):'发牌开局',()=>act('start'),
      {design:'primary',disabled:pending || s.people.length!==s.rules.players}));
    controls.push(button('添加电脑玩家',()=>chooseBotMode('添加电脑玩家','本地电脑（内置规则）','API 电脑（模型出牌）','需房主先启用电脑 API',mode=>act('bot',{mode})),{disabled:pending || s.people.length>=s.rules.players}));
    if (s.people.some(player=>player.bot)) controls.push(button('移除电脑玩家',()=>act('removeBot'),{disabled:pending}));
    controls.push(button('调整规则',()=>rulesForm(s.rules),{disabled:pending}));
  }
  if (own && active && autoplay) {
    controls.push(button('接管出牌',()=>act('autoplay',{enabled:false}),{disabled:pending}));
  }
  if (own && bidding && !autoplay) {
    controls.push(button('不叫',()=>act('bid',{bid:0},s.turnVersion),{disabled:pending}));
    const calls = s.rules.landlordCall==='call';
    for (let bid=s.bid+1;bid<=(calls ? 1 : 3);bid++) {
      controls.push(button(calls?'叫地主':'叫 '+bid+' 分',()=>act('bid',{bid},s.turnVersion),
        {design:'primary',disabled:pending}));
    }
  }
  if (own && playing && !autoplay) {
    board.passButton.disabled = pending || !s.last;
    board.hintButton.disabled = pending;
    board.playButton.disabled = pending || checkingPlay || !selected.size || Boolean(preview?.issue);
    board.aiButton.disabled = pending;
    board.aiButton.textContent = s.aiHint ? '重新生成' : 'AI 提示';
    controls.push(board.passButton,board.hintButton,board.aiButton,board.playButton);
  }
  if (board.version!==s.version) {
    board.version = s.version;
    const opponents = opponentSeats(s);
    const moves = turnMoves(s);
    if (!own) moves.delete(s.turn);
    board.roomText.replaceChildren(el('b',{},s.room),el('span',{},active
      ? '第 '+(s.round ?? 1)+(s.rounds?'/'+s.rounds:'')+' 局 · '+(s.multiplier ?? 1)+' 倍'
      : activeRuleNames.join(' · ')));
    const bottomCount = s.bottom.length || (bidding ? s.rules.bottom : 0);
    board.bottom.hidden = bottomCount === 0;
    if (bottomCount) {
      board.bottom.setAttribute('aria-label','地主底牌 '+bottomCount+' 张');
      const visible = Math.min(3,bottomCount);
      board.bottom.replaceChildren(...Array.from({length:visible},(_,index)=>
        s.bottom.length ? face({id:s.bottom[index]}) : el('span',{class:'bottom-back','aria-hidden':'true'})));
      if (bottomCount>visible) board.bottom.append(el('span',{class:'extra-bottom'},'+'+(bottomCount-visible)));
    }
    board.seats.dataset.count = String(opponents.length);
    board.seats.dataset.many = opponents.length > 3 ? 'true' : 'false';
    board.seats.replaceChildren(...opponents.map(player=>seatView(player,moves.get(player?.id))));
    const callLabel = s.rules.landlordCall==='call' ? '叫地主' : '叫分';
    const turnText = s.botThinking ? (own?'AI 代打思考中':playerName(s.turn)+' 思考中') :
      autoplay && own && active ? autoLabel+'中' :
      finalPlayTimer !== null ? (s.leader===s.you?'你率先出完':playerName(s.leader)+'率先出完') :
      s.phase==='finished' ? (s.result || '牌局结束') :
      bidding ? (own?'轮到你'+callLabel:playerName(s.turn)+'正在'+callLabel) :
      playing ? (own?(s.last?'轮到你出牌':'轮到你先出'):playerName(s.turn)+'正在出牌') :
      (s.people.length===s.rules.players?'座位已满，可以发牌':'等待其他玩家入座');
    const apiText = active && s.apiSuspended ? '本局本地接管' :
      active && s.apiTimeouts>0 ? '超时 '+s.apiTimeouts+'/'+(s.apiTimeoutLimit ?? 3) : '';
    board.status.textContent = turnText+(apiText?' · '+apiText:'');
    board.status.classList.toggle('thinking',s.botThinking === true);
    board.status.classList.toggle('your-turn',own && active);
    board.counter.hidden = !s.counter?.length;
    board.counter.replaceChildren(el('small',{},'未见'),
      ...(s.counter ?? []).map(({rank,count}) => el('span',{class:count===0?'exhausted':''},el('b',{},rankName(rank)),' '+count)));
    renderTrick(s, opponents, moves);
    renderSettlement(s);
    board.count.textContent = '我 · '+s.hand.length+' 张'+(s.debug?.forceOut?' · 强制出牌':'');
    board.ownRole.hidden = s.you!==s.landlord;
    board.ownMove.replaceChildren(...[autoplay ? el('span',{class:'move-tag move-previous'},autoLabel) : moveTag(moves.get(s.you))].filter(Boolean));
    board.wild.textContent = playing && s.wild.length ? '癞子 '+s.wild.map(rankName).join('、') : '';
    board.wild.hidden = !board.wild.textContent;
    updateChat();
  }
  board.controls.hidden = !controls.length;
  if (controls.length !== board.controls.children.length ||
      controls.some((control,index) => control !== board.controls.children[index])) {
    board.controls.replaceChildren(...controls);
  }
  const options = preview?.options;
  const pattern = options?.find(option => option.key === preferred) ??
    (options?.length === 1 ? options[0] : null);
  const label = pattern?.label ?? (options?.length > 1 ? options.length+' 种出法' : null);
  const text = !selected.size ? '' : preview?.issue ??
    (label ? label+' · '+selected.size+' 张' : '已选 '+selected.size+' 张');
  if (board.countSelected.textContent !== text) board.countSelected.textContent = text;
  board.countSelected.dataset.invalid = String(Boolean(preview?.issue));
  board.countSelected.dataset.ready = String(Boolean(label));
  board.clear.hidden = !selected.size;
  const coach = own && playing && !autoplay ? s.aiHint : null;
  board.advice.hidden = !coach || coach.pending;
  board.advice.disabled = !coach?.reason;
  board.advice.textContent = !coach || coach.pending ? '' :
    coach.error ?? 'AI 建议 · '+(coach.play ? '出牌 · '+coach.play.label : '不出')+' · '+coach.reason;
  const hintPending = coach?.pending === true;
  const progress = hintPending ? coach : s.botProgress;
  const waiting = hintPending || s.botThinking;
  board.aiWait.hidden = !waiting;
  if (waiting) {
    const stage = progress?.stage ?? 'waiting';
    const remaining = progress?.remaining ?? s.apiWaitSeconds ?? 45;
    const key = [s.turnVersion, coach?.id, stage, remaining].join('/');
    if (board.aiDeadline?.key!==key) {
      board.aiDeadline = {key,time:performance.now()+remaining*1000};
    }
    const stageText = {
      preparing:'正在准备牌面',connecting:'正在连接模型',waiting:'模型正在分析',
      receiving:'正在接收结果',retrying:'模型未给出答案，正在重试',
    }[stage] ?? '模型正在分析';
    if (board.aiStage.textContent!==stageText) board.aiStage.textContent = stageText;
    board.aiCancel.hidden = !hintPending && !host && !own;
    board.aiCancel.disabled = pending;
    board.aiCancel.textContent = hintPending ? '取消提示' : '本手用本地';
    updateAiTime();
  } else {
    board.aiDeadline = null;
    clearTimeout(board.aiTimer);
  }
  board.hand.node.hidden = !s.hand.length || s.phase==='finished';
  board.count.parentNode.hidden = board.hand.node.hidden;
  board.hand.update(s.hand.map(id=>({id})),selected,new Set(s.wild),canSelectCards());
  refreshCheats();
}

function updateAiTime() {
  if (!board?.aiDeadline) return;
  clearTimeout(board.aiTimer);
  const remaining = board.aiDeadline.time-performance.now();
  const seconds = Math.max(0,Math.ceil(remaining/1000));
  board.aiTime.textContent = seconds ? '剩余最多 '+seconds+' 秒' : '正在结束等待';
  if (seconds) board.aiTimer = setTimeout(updateAiTime,remaining-(seconds-1)*1000+20);
}

function isOwnTurn(seat, revision) {
  return session === seat && state?.phase === 'playing' &&
    state.you === state.turn && !ownAutoplay() && state.turnVersion === revision;
}
function activeSelectionCheck() {
  const revision = state?.turnVersion;
  if (selectionCheck && selectionCheck.turn === revision && selectionCheck.revision === selectionRevision) return selectionCheck;
  clearTimeout(selectionTimer);
  const check = {seat:session,turn:revision,revision:selectionRevision,cards:[...selected]};
  selectionCheck = check;
  selectionTimer = setTimeout(() => {
    if (selectionCheck !== check || !isOwnTurn(check.seat, check.turn)) return;
    loadSelectionCheck(check).catch(() => {});
  }, 135);
  return check;
}

function loadSelectionCheck(check) {
  check.request ??= request('/'+check.seat.room+'/options',{
    cards:check.cards,turnVersion:check.turn,
  },check.seat).then(({options}) => {
    check.options = options;
  }).catch(error => {
    if (error.status === 400) check.issue = error.message;
    else {
      check.request = null;
      throw error;
    }
  }).finally(() => {
    if (selectionCheck === check && isOwnTurn(check.seat,check.turn)) renderRoom();
  });
  return check.request;
}

async function hint() {
  const seat = session;
  const revision = state?.turnVersion;
  const currentSelection = selectionRevision;
  if (!seat || !isOwnTurn(seat, revision) || pending || loadingHints || checkingPlay || gestureActive()) return;
  if (hints === null) {
    loadingHints = true;
    try {
      const result = await request('/'+seat.room+'/hints',{turnVersion:revision},seat);
      if (!isOwnTurn(seat, revision) || selectionRevision !== currentSelection) return;
      hints = result.hints ?? [];
    } finally { loadingHints = false; }
  }
  if (!hints.length) {
    notice('没有可用的提示');
    return;
  }
  const play = hints[hintCursor % hints.length];
  hintCursor++;
  setSelection(new Set(play.cards.map(card => card.id)), play.key);
  renderRoom();
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
function playChoiceLabel(play) {
  const level = play.key.startsWith('rocket:') && state.rules.rocketBeatsChain
    ? '王炸优先' : play.bombLevel == null ? null : '等级 '+play.bombLevel;
  const conversions = new Set(play.cards
    .filter(card=>card.rank!=null && card.rank!==rankOf(card.id))
    .map(card=>rankName(rankOf(card.id))+'→'+rankName(card.rank)));
  return [play.label,level,play.bombMultiplier!=null?'×'+play.bombMultiplier:null,
    play.key.startsWith('rocket:')?null:rankName(play.high),...conversions]
    .filter(Boolean).join(' · ');
}
async function choosePlay() {
  const seat = session;
  const revision = state?.turnVersion;
  if (!seat || !isOwnTurn(seat, revision) || pending || checkingPlay || gestureActive() || !selected.size) return;
  const check = activeSelectionCheck();
  const cards = check.cards;
  const suggested = preferred;
  const stillSelected = () => isOwnTurn(seat, revision) && selectionRevision === check.revision;
  clearTimeout(selectionTimer);
  checkingPlay = true;
  renderRoom();
  try {
    await loadSelectionCheck(check);
  } finally {
    checkingPlay = false;
    renderRoom();
  }
  if (!stillSelected()) return;
  if (check.issue) return notice(check.issue);
  const options = check.options;
  const chosen = options.find(option => option.key === suggested) ?? (options.length === 1 ? options[0] : null);
  if (chosen) return act('play',{cards,pattern:chosen.key},revision);
  openDialog('选择出牌方式',options.map(option =>
    button(playChoiceLabel(option),() => {
      dialog.close();
      if (stillSelected()) return act('play',{cards,pattern:option.key},revision);
    })),button('取消',() => dialog.close()));
  dialog.dataset.playChoice = 'true';
}
async function act(action, data = {}, revision = state?.turnVersion) {
  if (pending || !session) return;
  if (['play','pass','bid'].includes(action) && revision !== state?.turnVersion) {
    notice('回合已变化，请刷新后再试');
    return;
  }
  const seat = session;
  pending = true;
  renderRoom();
  try {
    const value = await request('/'+seat.room+'/'+action,{...data,turnVersion:revision},seat);
    if (session !== seat) return;
    if (value.left) {
      try { sessionStorage.removeItem('dorm-cards:'+seat.room); } catch (_) {}
      releaseFan();
      state = session = null;
      appliedAiHintId = null;
      setSelection(new Set());
      clearBoard();
      await refresh(true);
    } else {
      pending = false;
      accept(value);
    }
  } finally {
    pending = false;
    renderRoom();
  }
}
function accept(value) {
  if (!value.phase || (state && value.version <= state.version)) return;
  const turnChanged = value.turnVersion !== state?.turnVersion;
  const samePlayingHand = state?.phase === 'playing' &&
    value.phase === 'playing' && sameHand(state, value);
  if (!samePlayingHand || (turnChanged && state.turn === state.you)) {
    releaseFan();
    setSelection(new Set());
  }
  if (turnChanged || !samePlayingHand) {
    hints = null;
    preferred = null;
    hintCursor = 0;
    selectionRevision++;
    if (dialog.dataset.playChoice === 'true') dialog.close();
  }
  const similarRoom = state?.room===value.room && state?.you===value.you;
  if (!similarRoom) unreadChat = 0;
  const events = similarRoom ? value.events.filter(item => item.id>currentEvents) : [];
  if (value.phase!=='finished' || value.room!==state?.room) {
    clearTimeout(finalPlayTimer);
    finalPlayTimer = null;
  } else if (state?.phase!=='finished' && value.last) {
    finalPlayTimer = setTimeout(() => {
      finalPlayTimer = null;
      if (!board) return;
      board.version = null;
      renderRoom();
      sound('finish');
    },finalPlayDuration);
  }
  state = value;
  const hint = state.aiHint;
  if (state.phase==='playing' && state.you===state.turn && !ownAutoplay() &&
      hint && !hint.pending && !hint.error && hint.turn===state.turnVersion &&
      hint.id!==appliedAiHintId) {
    appliedAiHintId = hint.id;
    if (!hint.pass && hint.play?.cards?.length) {
      const owned = new Set(state.hand);
      const ids = hint.play.cards.map(card => card.id);
      if (ids.every(id => owned.has(id))) {
        releaseFan();
        setSelection(new Set(ids), hint.play.key);
      }
    }
  }
  currentEvents = value.events.at(-1)?.id ?? 0;
  const messages = chatMessages(value);
  const incoming = similarRoom ? messages.filter(event=>event.id>currentChat&&event.from!==value.you) : [];
  currentChat = messages.at(-1)?.id ?? 0;
  const notifyChat = incoming.length && !chatOpen();
  if (incoming.length && (!chatOpen() || board.chatPanel.system)) unreadChat += incoming.length;
  renderRoom();
  updateChatBadge();
  const tomato = events.findLast(event=>event.kind==='tomato');
  if (tomato) board.seats.querySelector('[data-seat="'+tomato.target+'"]')?.classList.add('splat');
  const fallback = events.findLast(event=>['botFallback','botTurnFallback'].includes(event.kind));
  if (fallback) notice(fallback.text);
  if (notifyChat) {
    const latest = incoming.at(-1);
    notice(chatSpeaker(latest)+' · '+latest.text);
  }
  const soundEvent = events.findLast(event=>
    (finalPlayTimer===null||event.kind!=='finish') && (event.kind!=='chat'||event.from!==value.you));
  if (soundEvent) sound(soundEvent.kind);
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
    if (connectionLost) {
      connectionLost = false;
      notice('已恢复连接');
    }
  } catch (error) {
    if (session && error.message.includes('座位已失效')) {
      try { sessionStorage.removeItem('dorm-cards:'+session.room); } catch (_) {}
      releaseFan();
      session = state = null;
      setSelection(new Set());
      clearBoard();
      notice('座位已失效，请重新加入');
      setTimeout(() => run(refresh), 100);
    } else throw error;
  } finally { fetching=false; }
}
message.addEventListener('input',updateChat);
chat.addEventListener('submit',event=>{
  event.preventDefault();
  const text = message.value.trim();
  if (pending || !text) return;
  run(async()=>{
    if (!await actChat('chat',{text})) return;
    if (message.value.trim()===text) message.value = '';
    if (chatOpen()) board.chatPanel.feed.scrollTop = board.chatPanel.feed.scrollHeight;
    updateChat();
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
setInterval(() => {
  if (!document.hidden && (session || !dialog.open)) {
    refresh().catch(() => {
      if (session && !connectionLost) {
        connectionLost = true;
        notice('连接中断，正在重试…');
      }
    });
  }
}, 900);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && (session || !dialog.open)) refresh().catch(() => {});
});
document.addEventListener('keydown', event => {
  if ((event.ctrlKey || event.metaKey) && !event.altKey) {
    if (event.key === '+' || event.key === '=' || event.code === 'NumpadAdd') {
      event.preventDefault();
      applyWebScale(webScale + SCALE_STEP);
      return;
    }
    if (event.key === '-' || event.key === '_' || event.code === 'NumpadSubtract') {
      event.preventDefault();
      applyWebScale(webScale - SCALE_STEP);
      return;
    }
    if (event.key === '0' || event.code === 'Numpad0') {
      event.preventDefault();
      applyWebScale(1);
      return;
    }
  }
  if (!board || dialog.open || pending) return;
  const tag = document.activeElement?.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
  if (event.key === 'Escape' && canSelectCards() && selected.size) {
    event.preventDefault();
    changeSelection(new Set());
  } else if ((event.key === 'h' || event.key === 'H') && isOwnTurn(session, state?.turnVersion)) {
    event.preventDefault();
    hint();
  } else if (event.key === 'Enter' && isOwnTurn(session, state?.turnVersion) && !board.playButton.disabled) {
    event.preventDefault();
    choosePlay();
  }
});
