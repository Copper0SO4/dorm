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
  if (!response.ok) {
    const error = new Error(result.error || '无法连接牌桌');
    error.status = response.status;
    throw error;
  }
  return result;
}
function openDialog(title, ...parts) {
  delete dialog.dataset.playChoice;
  dialog.replaceChildren(el('div',{class:'stack'},el('h2',{},title),parts));
  if (!dialog.open) dialog.showModal();
}
function enter(next) {
  session = next;
  state = null;
  currentEvents = 0;
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
      ? '普通炸弹 ＜ 连炸 ＜ 王炸 ＜ 双王炸'
      : '普通炸弹 ＜ 王炸 ＜ 双王炸 ＜ 连炸';
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
  counts();
}
function buildLobby(rooms) {
  clearBoard();
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
  const seat = button('',()=>openDialog(player.name,
    button('🍅 丢番茄',async()=>{await act('tomato',{target:player.id});dialog.close();}),
    button('关闭',()=>dialog.close())),{design:'seat'+(player.id===state.turn?' turn':'')});
  seat.dataset.seat = player.id;
  if (moveLabels[move]) seat.dataset.move = move;
  seat.title = [player.name,role,called,moveLabels[move],automatic?autoLabel+'中':'',player.cards+' 张'].filter(Boolean).join(' · ');
  seat.append(el('span',{class:'seat-avatar','aria-hidden':'true'},player.bot?(player.botMode==='api'?'AI':'机'):Array.from(player.name)[0]),
    el('span',{class:'seat-text'},el('b',{},player.name),
      el('span',{class:'seat-meta'},role || called ? el('small',{},role || called) : null,moveTag(move))),
    el('strong',{class:'seat-count','aria-label': (automatic?autoLabel+'中，':'')+player.cards+' 张'},automatic?autoLabel+' · '+player.cards:player.cards));
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
function updateChat() {
  if (!board?.history.isConnected) return;
  board.history.replaceChildren(...state.events.slice(-24).reverse().map(event=>
    el('p',{},event.kind==='chat'?playerName(event.from)+' · '+event.text:event.text)));
}
function showChat() {
  openDialog('牌桌消息',board.history,chat,button('关闭',()=>dialog.close()));
  chat.hidden = false;
  updateChat();
}
function settingsMenu() {
  const extras = [];
  if (state.you===state.host && ['playing','bidding'].includes(state.phase)) {
    extras.push(button('结束牌局',()=>openDialog('结束当前牌局？',
      button('取消',()=>dialog.close()),button('结束牌局',async()=>{await act('abort');dialog.close();}))));
  }
  const last = state.last ?? state.previousTrick?.play;
  if (last) extras.push(button('查看上一手',()=>showCards(last.label,last.cards)));
  if (state.hand.length) extras.push(button('展开手牌',()=>showCards('我的手牌',state.hand.map(id=>({id})),canSelectCards())));
  openDialog('牌桌菜单',extras,
    button(muted?'打开音效':'关闭音效',()=>{by('audio').click();dialog.close();}),
    button('离开房间',leave),button('返回牌桌',()=>dialog.close(),{design:'primary'}));
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
  if (!board) return;
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
  const controls = el('div',{class:'play-controls'});
  const passButton = button('不出',() => act('pass',{},state?.turnVersion));
  const hintButton = button('提示',hint);
  const aiButton = button('AI 提示',()=>act('aiHint',{},state?.turnVersion));
  const playButton = button('出牌',choosePlay,{design:'primary'});
  const count = el('span',{class:'own-count'});
  const countSelected = el('span',{class:'selection-count','aria-live':'polite'});
  const clear = button('清空',()=>changeSelection(new Set()),{design:'text-action'});
  const expand = button('展开手牌',()=>showCards('我的手牌',state.hand.map(id=>({id})),canSelectCards()),
    {design:'text-action'});
  expand.hidden = true;
  const hand = el('div',{class:'hand-canvas',role:'group','aria-label':'我的手牌'});
  const history = el('div',{class:'message-history'});
  const surface = el('section',{class:'card-stage','aria-label':'斗地主牌桌'},
    el('div',{class:'table-top'},
      el('div',{class:'table-head'},roomText,el('div',{class:'bottom-slot'},bottom),
        el('div',{class:'head-tools'},autoButton,button('消息',showChat),button('分享',share),fullscreen,button('更多',settingsMenu))),
      counter),
    seats,
    el('div',{class:'trick-zone'},spots,summary),
    el('div',{class:'action-row'},el('div',{class:'action-status'},status,wild),controls),
    el('div',{class:'hand-line'},count,ownMove,countSelected,clear,expand,advice),
    hand);
  document.body.classList.add('at-table');
  content.replaceChildren(surface);
  return {surface,roomText,bottom,seats,status,wild,spots,counter,autoButton,summary,advice,controls,
    passButton,hintButton,aiButton,playButton,
    count,ownMove,countSelected,clear,expand,history,
    hand:new CardSurface(hand,{onSelection:changeSelection,onDense:dense=>{expand.hidden=!dense;}}),
    lanes:new Map(),version:null};
}

function renderTrick(s, opponents, moves) {
  const previous = s.last ? null : s.previousTrick;
  const played = s.last ?? previous?.play;
  const actor = s.leader ?? previous?.leader;
  const entries = new Map((s.last ? s.tablePlays ?? [] : []).map(item => [item.seat, item.play]));
  if (played && actor != null) entries.set(actor, played);
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
        const splash = el('span',{class:'power-banner','aria-hidden':'true'},play.label+' ×2');
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
    if (state?.turnVersion !== hint.turn || ownAutoplay()) return;
    setSelection(new Set(play.cards.map(card => card.id)),play.key);
    renderRoom();
    dialog.close();
  },{design:'primary'}));
  buttons.push(button('关闭',()=>dialog.close()));
  openDialog('AI 建议 · '+(play?.label ?? '不出'),el('p',{},hint.reason),el('div',{class:'actions'},buttons));
}

function renderSettlement(s) {
  const summary = s.settlement;
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
  board.autoButton.textContent = autoplay ? '取消'+autoLabel : '托管';
  board.autoButton.setAttribute('aria-pressed',String(autoplay));
  const controls = [];
  if (host && !active) {
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
    board.aiButton.disabled = pending || s.aiHint?.pending === true;
    controls.push(board.passButton,board.hintButton,board.aiButton,board.playButton);
  }
  if (board.version!==s.version) {
    board.version = s.version;
    const opponents = opponentSeats(s);
    const moves = turnMoves(s);
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
    board.seats.replaceChildren(...opponents.map(player=>seatView(player,moves.get(player?.id))));
    const callLabel = s.rules.landlordCall==='call' ? '叫地主' : '叫分';
    const turnText = s.botThinking ? (own?'AI 代打思考中':playerName(s.turn)+' 思考中') :
      autoplay && own && active ? autoLabel+'中' :
      s.phase==='finished' ? (s.result || '牌局结束') :
      bidding ? (own?'轮到你'+callLabel:playerName(s.turn)+'正在'+callLabel) :
      playing ? (own?(s.last?'轮到你出牌':'轮到你先出'):playerName(s.turn)+'正在出牌') :
      (s.people.length===s.rules.players?'座位已满，可以发牌':'等待其他玩家入座');
    const apiText = s.botThinking ? '最多 '+(s.apiWaitSeconds ?? 45)+'s' :
      active && s.apiSuspended ? '本局本地接管' :
      active && s.apiTimeouts>0 ? '超时 '+s.apiTimeouts+'/'+(s.apiTimeoutLimit ?? 3) : '';
    board.status.textContent = turnText+(apiText?' · '+apiText:'');
    board.status.classList.toggle('thinking',s.botThinking === true);
    board.status.classList.toggle('your-turn',own && active);
    board.counter.hidden = !s.counter?.length;
    board.counter.replaceChildren(el('small',{},'未见'),
      ...(s.counter ?? []).map(({rank,count}) => el('span',{class:count===0?'exhausted':''},el('b',{},rankName(rank)),' '+count)));
    renderTrick(s, opponents, moves);
    renderSettlement(s);
    board.count.textContent = '我 · '+s.hand.length+' 张'+(s.you===s.landlord?' · 地主':'');
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
  board.advice.hidden = !coach;
  board.advice.disabled = !coach?.reason;
  board.advice.textContent = !coach ? '' : coach.pending ? 'AI 分析中 · 最多 '+(s.apiWaitSeconds ?? 45)+' 秒'
    : coach.error ?? 'AI 建议 · '+(coach.play?.label ?? '不出')+' · '+coach.reason;
  board.hand.node.hidden = !s.hand.length || s.phase==='finished';
  board.count.parentNode.hidden = board.hand.node.hidden;
  board.hand.update(s.hand.map(id=>({id})),selected,new Set(s.wild),canSelectCards());
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
    button(option.label+' · '+rankName(option.high),() => {
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
  const events = state ? value.events.filter(item => item.id>currentEvents) : [];
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
  renderRoom();
  const tomato = events.findLast(event=>event.kind==='tomato');
  if (tomato) board.seats.querySelector('[data-seat="'+tomato.target+'"]')?.classList.add('splat');
  const fallback = events.findLast(event=>['botFallback','botTurnFallback'].includes(event.kind));
  if (fallback) notice(fallback.text);
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
      releaseFan();
      session = state = null;
      setSelection(new Set());
      clearBoard();
      notice('座位已失效，请重新加入');
      setTimeout(() => run(refresh), 100);
    } else throw error;
  } finally { fetching=false; }
}
chat.addEventListener('submit',event=>{
  event.preventDefault();
  const text = message.value.trim();
  if (pending || !text) return;
  run(async()=>{
    await act('chat',{text});
    message.value = '';
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
