'use strict';

const cardRanks = {11:'J',12:'Q',13:'K',14:'A',15:'2',16:'小王',17:'大王'};
const cardSuits = ['♠','♥','♦','♣'];
const rankName = rank => cardRanks[rank] ?? String(rank);
const rankOf = id => id%54 < 52 ? 3+Math.floor((id%54)/4) : id%54-36;
const suitOf = id => id%54 < 52 ? cardSuits[id%54%4] : '';
const isRotatedTable = () => document.body.classList.contains('at-table') &&
  matchMedia('(orientation: portrait) and (pointer: coarse)').matches;

function cardLayout(cards, availableWidth, availableHeight, interactive, tightSpacing) {
  const width = Math.max(0, availableWidth-10);
  const rowWidth = tightSpacing ? Math.min(width,1120) : width;
  const singleLift = interactive ? Math.min(15, availableHeight*.18) : 0;
  const natural = Math.min(interactive?94:59, (availableHeight-singleLift-5)/1.34, width);
  if (!cards.length || natural <= 0) return {boxes:[], rows:0, rowStep:0, lift:0, dense:false};
  const peek = interactive ? Math.min(22, Math.max(16, natural*.27)) : 13;
  const twoRows = cards.length > 1 && (cards.length-1)*peek+natural > rowWidth;
  const widthRatio = tightSpacing ? .38 : (interactive ? .61 : .74);
  const rowStep = twoRows ? Math.min(interactive?47:31, Math.floor(availableHeight*.36)) : 0;
  const lift = interactive && twoRows ? Math.min(9,availableHeight*.09) : singleLift;
  const cardWidth = Math.max(1,Math.min(natural, (availableHeight-lift-rowStep-5)/1.34));
  const cardHeight = cardWidth*1.34;
  const top = availableHeight-cardHeight-rowStep-3;
  const split = twoRows ? Math.ceil(cards.length/2) : cards.length;
  const boxes = [];
  for (const [row, group] of [cards.slice(0,split),cards.slice(split)].entries()) {
    if (!group.length) break;
    const gaps = group.slice(1).filter((card,i) => rankOf(group[i].id)!==rankOf(card.id)).length;
    const intervals = group.length-1+(interactive?gaps*.11:0);
    const step = intervals ? Math.min(cardWidth*widthRatio, (rowWidth-cardWidth)/intervals) : cardWidth;
    let left = (availableWidth-cardWidth-intervals*step)/2;
    for (const [index, card] of group.entries()) {
      const next = group[index+1];
      const gap = next && interactive && rankOf(card.id)!==rankOf(next.id) ? step*.11 : 0;
      boxes.push({card,index:boxes.length,row,left,top:top+row*rowStep,width:cardWidth,height:cardHeight,
        peek:next?step+gap:cardWidth,cornerHeight:twoRows && row===0?rowStep-lift-4:Infinity,lift:0,raised:false});
      left += step+gap;
    }
  }
  return {boxes, rows:twoRows?2:1,rowStep,lift,dense:boxes.some(box=>box.peek<15)};
}

const diamondArt = new Path2D('M0 -1 .73 0 0 1 -.73 0Z');
const pipArt = [
  new Path2D('M0 -1 C.18 -.72 .94 -.28 .94 .22 C.94 .68 .4 .79 .16 .44 Q.14 .72 .44 .96 H-.44 Q-.14 .72 -.16 .44 C-.4 .79 -.94 .68 -.94 .22 C-.94 -.28 -.18 -.72 0 -1Z'),
  new Path2D('M0 .95 C-.3 .6 -.95 .11 -.95 -.4 C-.95 -.95 -.25 -1.06 0 -.51 C.25 -1.06 .95 -.95 .95 -.4 C.95 .11 .3 .6 0 .95Z'),
  diamondArt,
  new Path2D('M0 -.99 A.52 .52 0 1 1 -.001 -.99Z M-.45 -.28 A.49 .49 0 1 1 -.451 -.28Z M.45 -.28 A.49 .49 0 1 1 .449 -.28Z M-.17 .22H.17 Q.12 .66 .42 .95 H-.42 Q-.12 .66 -.17 .22Z'),
];
function paintPip(ctx, path, x, y, radius, color) {
  ctx.save();
  ctx.translate(x,y);
  ctx.scale(radius,radius);
  ctx.fillStyle = color;
  ctx.fill(path);
  ctx.restore();
}

function paintCorner(ctx, rank, path, width, visible, cornerHeight, ink) {
  const inset = Math.min(6,Math.max(1,visible*.15));
  const room = Math.max(2,visible-inset-2);
  const size = Math.max(6,Math.min(width*.32,visible*.90,cornerHeight/1.90));
  const name = rankName(rank);
  const top = rank>=16 ? name[0] : name;
  ctx.fillStyle = ink;
  ctx.textBaseline = 'top';
  ctx.textAlign = 'start';
  ctx.font = '900 '+size+'px system-ui,sans-serif';
  const used = Math.min(room,ctx.measureText(top).width);
  ctx.fillText(top,inset,3,room);
  if (rank>=16) {
    ctx.font = '850 '+size*.83+'px system-ui,sans-serif';
    ctx.fillText('王',inset,3+size,room);
  } else {
    const pip = Math.min(size*.35,room/2);
    paintPip(ctx,path,inset+Math.max(pip,used/2),4+size+pip,pip,ink);
  }
}

function paintFace(ctx, rank, suit, path, width, height, ink) {
  const centerX = width*.55;
  const centerY = height*.57;
  ctx.save();
  if (suit===null || (rank>=11 && rank<=13)) {
    ctx.beginPath();
    ctx.roundRect(centerX-width*.24,centerY-height*.215,width*.48,height*.43,7);
    ctx.fillStyle = ink+'19';
    ctx.fill();
    ctx.strokeStyle = ink+'66';
    ctx.stroke();
    paintPip(ctx,path,centerX,centerY-height*.045,width*.133,ink+'d1');
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.font = '850 '+width*.16+'px system-ui,sans-serif';
    ctx.fillStyle = ink+'c7';
    ctx.fillText(suit===null?'王':rankName(rank),centerX,centerY+height*.06,width*.36);
  } else {
    const spots = rank===14 ? 1 : rank===15 ? 2 : rank;
    if (spots===1) paintPip(ctx,path,centerX,centerY,width*.24,ink);
    else {
      const rows = spots<=3 ? spots : spots<=5 ? 2 : spots<=8 ? 3 : 4;
      for (let row=0;row<rows;row++) {
        const y=height*(.33+.45*row/(rows-1));
        for (const side of spots<=3 ? [0] : [-1,1]) {
          paintPip(ctx,path,centerX+side*width*.16,y,width*.082,ink+'d4');
        }
      }
      const centerSpots={5:[.55],7:[.44],8:[.43,.67],9:[.55],10:[.43,.67]};
      for (const y of centerSpots[spots] ?? []) {
        paintPip(ctx,path,centerX,height*y,width*.075,ink+'d4');
      }
    }
  }
  ctx.restore();
}

function paintCard(ctx, box, wild, hovered = false) {
  const {card,left,width,height,peek,raised} = box;
  const y = box.top-box.lift;
  const rank = card.rank ?? rankOf(card.id);
  const suit = card.id%54<52 ? card.id%54%4 : null;
  const path = suit===null ? diamondArt : pipArt[suit];
  const ink = suit===1 || suit===2 || rank===17 ? '#a31e2d' : '#152e2b';
  const marked = wild.has(rankOf(card.id));
  const radius = Math.min(10,width*.16);
  ctx.save();
  ctx.translate(left,y);
  ctx.beginPath();
  ctx.roundRect(0,2,width,height,radius);
  ctx.fillStyle = raised ? '#08110996' : '#08110970';
  ctx.fill();
  ctx.beginPath();
  ctx.roundRect(0,0,width,height,radius);
  const paper=ctx.createLinearGradient(0,0,width,height);
  paper.addColorStop(0,raised?'#fff6d3':hovered?'#fffdf2':'#fffff9');
  paper.addColorStop(1,raised?'#f0cea0':hovered?'#f6ebd3':'#eee3cc');
  ctx.fillStyle = paper;
  ctx.fill();
  ctx.strokeStyle = raised ? '#ffbf51' : hovered ? '#e5c47e' : marked ? '#c6813d' : '#9aab97';
  ctx.lineWidth = raised ? 2 : hovered ? 1.5 : 1;
  ctx.stroke();

  if (peek>=width*.58 && width>=29) {
    ctx.beginPath();
    ctx.roundRect(3,3,width-6,height-6,Math.max(2,radius-2));
    ctx.strokeStyle = ink+'26';
    ctx.lineWidth = .65;
    ctx.stroke();
    paintFace(ctx,rank,suit,path,width,height,ink);
    if (width>52 && rank<16) {
      ctx.save();
      ctx.translate(width,height);
      ctx.rotate(Math.PI);
      paintCorner(ctx,rank,path,width,width,box.cornerHeight,ink);
      ctx.restore();
    }
  }
  paintCorner(ctx,rank,path,width,peek,box.cornerHeight,ink);
  if (marked && width>25) paintPip(ctx,diamondArt,width-7,7,2.7,'#b36f16');
  ctx.restore();
}

class CardSurface {
  constructor(node,{onSelection=null,onDense=null}={}) {
    this.node = node;
    this.onSelection = onSelection;
    this.onDense = onDense;
    this.cards = [];
    this.selected = new Set();
    this.wild = new Set();
    this.boxes = [];
    this.enabled = false;
    this.gesture = null;
    this.hoverIndex = -1;
    this.frame = 0;
    this.canvas = document.createElement('canvas');
    this.canvas.setAttribute('aria-hidden','true');
    this.ctx = this.canvas.getContext('2d');
    node.append(this.canvas);
    if (onSelection) {
      this.keys = document.createElement('div');
      this.keys.className = 'card-keys';
      node.append(this.keys);
      node.addEventListener('pointerdown',event=>this.down(event));
      node.addEventListener('pointermove',event=>this.move(event));
      node.addEventListener('pointerup',event=>this.up(event));
      node.addEventListener('pointerleave',()=>this.clearHover());
      node.addEventListener('pointercancel',event=>this.cancelPointer(event));
      node.addEventListener('lostpointercapture',event=>this.cancelPointer(event));
      this.keys.addEventListener('click',event=>{
        const target = event.target.closest('button');
        if (!target || !this.enabled || this.gesture) return;
        const id = Number(target.dataset.card);
        const next = new Set(this.selected);
        if (!next.delete(id)) next.add(id);
        this.onSelection(next);
      });
    }
    this.observer = new ResizeObserver(()=>this.layout());
    this.observer.observe(node);
  }

  update(cards,selected=new Set(),wild=new Set(),enabled=false) {
    const changed = cards.length!==this.cards.length ||
      cards.some((card,i)=>card.id!==this.cards[i].id || card.rank!==this.cards[i].rank);
    if (changed || !enabled) {
      this.cancel();
      this.hoverIndex = -1;
    }
    this.selected = selected;
    this.wild = wild;
    this.enabled = enabled;
    this.node.dataset.locked = String(!enabled);
    if (changed) {
      this.cards = cards;
      if (this.keys) {
        this.keys.replaceChildren(...cards.map(card=>{
          const key = document.createElement('button');
          key.type = 'button';
          key.dataset.card = card.id;
          key.setAttribute('aria-label',rankName(card.rank ?? rankOf(card.id))+suitOf(card.id));
          return key;
        }));
      }
      this.layout();
    }
    this.refreshKeys();
    this.schedule();
  }

  layout() {
    const width = this.node.clientWidth;
    const height = this.node.clientHeight;
    if (!width || !height) return;
    const uiScale = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ui-scale')) || 1;
    const scale = Math.min((devicePixelRatio || 1) * Math.max(1, uiScale),3);
    if (width===this.width && height===this.height && this.laidOut===this.cards && scale===this.scale) return;
    this.cancel();
    const former = new Map(this.boxes.map(box=>[box.card.id,box.lift]));
    this.width = width;
    this.height = height;
    this.scale = scale;
    this.laidOut = this.cards;
    this.canvas.width = Math.round(width*scale);
    this.canvas.height = Math.round(height*scale);
    this.ctx.setTransform(scale,0,0,scale,0,0);
    const interactive = Boolean(this.onSelection);
    const tightSpacing = interactive && matchMedia('(pointer: fine)').matches;
    const layout = cardLayout(this.cards,width,height,interactive,tightSpacing);
    this.boxes = layout.boxes;
    this.rowStep = layout.rowStep;
    this.lift = layout.lift;
    this.node.dataset.rows = String(layout.rows);
    this.node.style.setProperty('--card-lift',layout.lift+'px');
    const keys = this.keys?.children;
    for (const box of this.boxes) {
      box.lift = former.get(box.card.id) ?? (this.selected.has(box.card.id) ? this.lift : 0);
      const key = keys?.[box.index];
      if (key) Object.assign(key.style,{left:box.left+'px',top:box.top+'px',
        width:box.width+'px',height:box.height+'px'});
    }
    this.onDense?.(layout.dense);
    this.schedule();
  }

  refreshKeys() {
    if (!this.keys) return;
    for (const key of this.keys.children) {
      key.disabled = !this.enabled;
      key.setAttribute('aria-pressed',String(this.selected.has(Number(key.dataset.card))));
    }
  }

  raised(box) {
    const active = this.gesture;
    if (active && box.index>=Math.min(active.anchor,active.end) &&
        box.index<=Math.max(active.anchor,active.end)) return active.raising;
    return this.selected.has(box.card.id);
  }

  schedule() {
    if (!this.frame) this.frame = requestAnimationFrame(()=>this.paint());
  }

  paint() {
    this.frame = 0;
    if (!this.width || !this.height) return;
    let moving = false;
    const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
    for (const box of this.boxes) {
      box.raised = this.raised(box);
      const target = box.raised ? this.lift : 0;
      box.lift = reduce || Math.abs(target-box.lift)<.7 ? target : box.lift+(target-box.lift)*.44;
      moving ||= box.lift!==target;
    }
    this.ctx.clearRect(0,0,this.width,this.height);
    for (const box of this.boxes) paintCard(this.ctx,box,this.wild,this.enabled && box.index===this.hoverIndex);
    if (moving) this.schedule();
  }

  hitBox(event) {
    const point = this.point(event);
    return this.boxes.findLast(box=>point.x>=box.left && point.x<=box.left+box.width &&
      point.y>=box.top-box.lift && point.y<=box.top-box.lift+box.height);
  }

  clearHover() {
    if (this.hoverIndex !== -1) {
      this.hoverIndex = -1;
      this.schedule();
    }
  }

  point(event) {
    const rect = this.canvas.getBoundingClientRect();
    if (isRotatedTable()) {
      const rx = this.width / (rect.height || this.width || 1);
      const ry = this.height / (rect.width || this.height || 1);
      return {x:(event.clientY-rect.top)*rx,y:(rect.right-event.clientX)*ry};
    }
    const sx = this.width / (rect.width || this.width || 1);
    const sy = this.height / (rect.height || this.height || 1);
    return {x:(event.clientX-rect.left)*sx,y:(event.clientY-rect.top)*sy};
  }

  down(event) {
    if (!this.enabled || this.gesture || event.button!==0) return;
    const hit = this.hitBox(event);
    if (!hit) return;
    this.hoverIndex = -1;
    this.node.setPointerCapture(event.pointerId);
    this.gesture = {pointer:event.pointerId,anchor:hit.index,end:hit.index,start:this.point(event),
      raising:!this.selected.has(hit.card.id),dragging:false};
    this.schedule();
  }

  locate(event) {
    const active = this.gesture;
    const pos = this.point(event);
    const dx = pos.x-active.start.x;
    const dy = pos.y-active.start.y;
    if (!active.dragging && Math.hypot(dx,dy)<7) return active.anchor;
    active.dragging = true;
    const anchor = this.boxes[active.anchor];
    const row = this.rowStep ? Math.min(1,Math.max(0,anchor.row+Math.round(dy/this.rowStep))) : 0;
    const lane = row===anchor.row ? anchor.left+anchor.peek/2+dx : pos.x;
    const boxes = this.boxes.filter(box=>box.row===row);
    return (boxes.findLast(box=>box.left<=lane) ?? boxes[0]).index;
  }

  move(event) {
    if (!this.gesture) {
      if (!this.enabled || event.pointerType === 'touch') return;
      const hit = this.hitBox(event);
      const next = hit ? hit.index : -1;
      if (next !== this.hoverIndex) {
        this.hoverIndex = next;
        this.schedule();
      }
      return;
    }
    if (this.gesture.pointer!==event.pointerId) return;
    const end = this.locate(event);
    if (this.gesture.end!==end) {
      this.gesture.end = end;
      this.schedule();
    }
  }

  up(event) {
    if (this.gesture?.pointer!==event.pointerId) return;
    const {anchor,raising} = this.gesture;
    const end = this.locate(event);
    const ids = new Set(this.selected);
    for (let i=Math.min(anchor,end);i<=Math.max(anchor,end);i++) {
      const id = this.boxes[i].card.id;
      if (raising) ids.add(id); else ids.delete(id);
    }
    this.cancel();
    this.onSelection(ids);
  }

  cancelPointer(event) {
    if (this.gesture?.pointer===event.pointerId) this.cancel();
  }

  cancel() {
    if (!this.gesture) return;
    const {pointer} = this.gesture;
    this.gesture = null;
    if (this.node.hasPointerCapture(pointer)) this.node.releasePointerCapture(pointer);
    this.schedule();
  }

  dispose() {
    this.cancel();
    cancelAnimationFrame(this.frame);
    this.observer.disconnect();
  }
}
