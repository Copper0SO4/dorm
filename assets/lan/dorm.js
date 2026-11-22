'use strict';

const byId = (id) => document.getElementById(id);
const content = byId('content');
const dialog = byId('dialog');
const viewerSelect = byId('viewer-select');
const paletteSelect = byId('palette-select');
const einkToggle = byId('eink-toggle');
const sections = {
  ledger: ['公共账本', '查看账单、成员余额与待付汇总，支持新建开销与一键批量结算。'],
  chores: ['卫生排班', '查看每天的值日安排、完成打卡或临时换人改派。'],
  supplies: ['公共物资', '管理库存、筛选缺货采购状态、记账或清理物资。'],
  matters: ['寝室事务', '跟进报修、活动准备和其他共同事项。'],
  members: ['寝室成员', '管理室友名单，支持新增、改名、停用与安全删除成员。'],
  tools: ['娱乐工具', '寝室决策盲盒、数字炸弹、抽签分组与骰子硬币，局域网随时开玩。'],
};
const purchaseStates = {stocked: '已入库', needed: '待采购', ordered: '采购中'};
const matterStates = {open: '待处理', doing: '进行中', done: '已完成'};
const filters = {
  query: '',
  unpaid: false,
  page: 0,
  day: '',
  supplyQuery: '',
  supplyNeedOnly: false,
  archived: false,
  onlyMine: false,
};
let current = readInitialSection();
let renderId = 0;
let toastTimer;
let browserDevice;
let lastToolsData = null;

function readInitialSection() {
  const key = location.hash.replace(/^#/, '');
  return sections[key] ? key : 'ledger';
}

function getViewerId() {
  try {
    const raw = localStorage.getItem('dorm-viewer-id');
    return raw ? Number(raw) : null;
  } catch (_) {
    return null;
  }
}

function setViewerId(id) {
  try {
    if (id) localStorage.setItem('dorm-viewer-id', String(id));
    else localStorage.removeItem('dorm-viewer-id');
  } catch (_) {}
}

function deviceCode() {
  if (browserDevice) return browserDevice;
  try {
    const saved = localStorage.getItem('dorm-browser-device');
    if (/^[a-f0-9]{32}$/.test(saved)) return browserDevice = saved;
  } catch (_) {}
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  browserDevice = Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
  try { localStorage.setItem('dorm-browser-device', browserDevice); } catch (_) {}
  return browserDevice;
}

function node(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value !== false && value !== null && value !== undefined) {
      element.setAttribute(name, value === true ? '' : String(value));
    }
  }
  for (const child of children.flat()) {
    if (child !== undefined && child !== null) {
      element.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
  }
  return element;
}

function button(label, action, kind = '') {
  const element = node('button', {type: 'button', class: kind}, label);
  if (action) element.addEventListener('click', () => run(action));
  else element.disabled = true;
  return element;
}

function message(text) {
  const toast = byId('toast');
  toast.textContent = text;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 2600);
}

async function copyText(text) {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      message('已复制到剪贴板');
      return;
    }
  } catch (_) {}
  const box = node('textarea', {rows: 4, readonly: true}, text);
  openDialog('复制内容', [node('div', {class: 'stack'}, node('small', {}, '当前环境不支持自动写入剪贴板，请手动全选复制：'), box)]);
  box.select();
}

async function run(action) {
  try { await action(); } catch (error) { message(error.message); }
}

async function request(path, data) {
  let response;
  try {
    response = await fetch(path, {
      method: data === undefined ? 'GET' : 'POST',
      headers: data === undefined ? {} : {'Content-Type': 'application/json'},
      body: data === undefined ? undefined : JSON.stringify({...data, browserDevice: deviceCode()}),
      cache: 'no-store',
    });
  } catch (_) {
    throw new Error('连接服务器失败。请检查 Dorm 是否仍在运行。');
  }
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '操作失败');
  return result;
}

const money = (cents) => '¥' + (cents / 100).toFixed(2);
function time(value) {
  const date = new Date(value);
  return isNaN(date.getTime()) ? value : date.toLocaleString('zh-CN', {hour12: false});
}
const empty = (label) => node('p', {class: 'empty'}, label);
const label = (text, control) => node('label', {}, text, control);
const input = (name, value = '', attrs = {}) => node('input', {name, value, ...attrs});
const badge = (text, warning = false, danger = false) =>
  node('span', {class: danger ? 'badge danger-soft' : (warning ? 'badge warn' : 'badge')}, text);

function select(name, options, value) {
  const control = node('select', {name});
  for (const [key, text] of options) control.append(node('option', {value: key}, text));
  control.value = String(value ?? '');
  return control;
}

function openDialog(title, children) {
  byId('dialog-title').textContent = title;
  byId('dialog-body').replaceChildren(...children);
  if (!dialog.open) dialog.showModal();
}

function editor(title, fields, saveLabel, submit, kind = 'primary') {
  const ok = node('button', {type: 'submit', class: kind}, saveLabel);
  const error = node('p', {class: 'error', role: 'alert'});
  const form = node('form', {class: 'dialog-form'}, fields, ok, error);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (ok.disabled) return;
    ok.disabled = true;
    error.textContent = '';
    try {
      await submit(new FormData(form));
      dialog.close();
      await render();
    } catch (problem) {
      if (dialog.open) error.textContent = problem.message;
      else message(problem.message);
    } finally {
      ok.disabled = false;
    }
  });
  openDialog(title, [form]);
}

function syncViewerOptions(members) {
  if (!viewerSelect) return;
  const saved = getViewerId();
  const active = members.filter((m) => m.active);
  viewerSelect.replaceChildren(
    node('option', {value: ''}, '全部成员视角'),
    ...active.map((m) => node('option', {value: m.id}, '我是 ' + m.name))
  );
  if (saved && active.some((m) => m.id === saved)) {
    viewerSelect.value = String(saved);
  } else {
    viewerSelect.value = '';
    if (saved) setViewerId(null);
  }
}

if (viewerSelect) {
  viewerSelect.addEventListener('change', () => {
    const val = viewerSelect.value ? Number(viewerSelect.value) : null;
    setViewerId(val);
    run(render);
  });
}

function applyWebTheme(palette, eink) {
  const safePalette = ['pine', 'ocean', 'amber', 'plum', 'crimson', 'slate'].includes(palette) ? palette : 'pine';
  document.documentElement.dataset.palette = safePalette;
  document.documentElement.dataset.eink = eink ? 'true' : 'false';
  if (paletteSelect) paletteSelect.value = safePalette;
  if (einkToggle) einkToggle.setAttribute('aria-pressed', eink ? 'true' : 'false');
}

(function initWebTheme() {
  let palette = 'pine';
  let eink = false;
  try {
    palette = localStorage.getItem('dorm-web-palette') || 'pine';
    eink = localStorage.getItem('dorm-web-eink') === 'true';
  } catch (_) {}
  applyWebTheme(palette, eink);
  if (paletteSelect) {
    paletteSelect.addEventListener('change', () => {
      const next = paletteSelect.value;
      try { localStorage.setItem('dorm-web-palette', next); } catch (_) {}
      applyWebTheme(next, document.documentElement.dataset.eink === 'true');
    });
  }
  if (einkToggle) {
    einkToggle.addEventListener('click', () => {
      const next = document.documentElement.dataset.eink !== 'true';
      try { localStorage.setItem('dorm-web-eink', String(next)); } catch (_) {}
      applyWebTheme(document.documentElement.dataset.palette, next);
    });
  }
})();

byId('refresh').addEventListener('click', () => run(render));
byId('dialog-close').addEventListener('click', () => dialog.close());
document.querySelectorAll('[data-section]').forEach((item) => {
  item.addEventListener('click', () => {
    current = item.dataset.section;
    location.hash = current;
    content.replaceChildren(empty('正在读取数据…'));
    run(render);
  });
});

window.addEventListener('hashchange', () => {
  const next = readInitialSection();
  if (next !== current) {
    current = next;
    run(render);
  }
});

async function refreshViewerBar() {
  try {
    const members = await request('/api/members');
    syncViewerOptions(members);
  } catch (_) {}
}

async function render() {
  const id = ++renderId;
  const section = current;
  byId('section-title').textContent = sections[section][0];
  byId('section-description').textContent = sections[section][1];
  document.querySelectorAll('[data-section]').forEach((item) => {
    if (item.dataset.section === section) item.setAttribute('aria-current', 'page');
    else item.removeAttribute('aria-current');
  });
  const params = new URLSearchParams();
  if (section === 'ledger') {
    params.set('query', filters.query);
    params.set('unpaid', String(filters.unpaid));
    params.set('page', String(filters.page));
  }
  if (section === 'chores' && filters.day) params.set('day', filters.day);
  const status = byId('server-status');
  try {
    const data = await request('/api/' + section + (params.toString() ? '?' + params : ''));
    if (id !== renderId) return;
    if (section === 'members') syncViewerOptions(data);
    else if (viewerSelect && viewerSelect.options.length === 0) await refreshViewerBar();
    if (section === 'tools') lastToolsData = data;
    const view = {
      ledger: ledgerView,
      chores: choreView,
      supplies: supplyView,
      matters: matterView,
      members: memberView,
      tools: renderToolsSection,
    }[section];
    content.replaceChildren(view(data));
    status.textContent = '局域网连接';
    status.classList.add('online');
  } catch (error) {
    if (id !== renderId) return;
    status.textContent = '连接异常';
    status.classList.remove('online');
    content.replaceChildren(empty(error.message));
  }
}

function renderToolsSection(data) {
  const toolsData = data || lastToolsData;
  if (!window.dormToolsView) return empty('工具箱脚本未加载');
  return window.dormToolsView(toolsData, {
    node,
    button,
    input,
    badge,
    message,
    openDialog,
    dialog,
    copyText,
    rerender: () => {
      if (current === 'tools' && lastToolsData) {
        content.replaceChildren(renderToolsSection(lastToolsData));
      }
    },
  });
}

function ledgerView(data) {
  const viewerId = getViewerId();
  const search = node('form', {},
    input('query', filters.query, {placeholder: '搜索账单或付款人', 'aria-label': '搜索账单', maxlength: 80}),
    label('仅待结清', input('unpaid', 'yes', {type: 'checkbox', checked: filters.unpaid})),
    node('button', {type: 'submit'}, '筛选'));
  search.addEventListener('submit', (event) => {
    event.preventDefault();
    const form = new FormData(search);
    filters.query = form.get('query');
    filters.unpaid = form.has('unpaid');
    filters.page = 0;
    run(render);
  });

  const metric = (caption, value, extra = '') => node('article', {class: 'metric ' + extra}, node('small', {}, caption), node('strong', {}, value));

  const openPairs = data.openSettlements || [];
  const settlementPanel = openPairs.length ? node('section', {class: 'panel stack'},
    node('div', {class: 'toolbar'},
      node('strong', {}, '待结清汇总（' + openPairs.length + ' 组）'),
      button('复制待付清单', () => {
        const lines = openPairs.map((pair) => pair.debtor + ' → ' + pair.payer + ' ' + money(pair.total));
        return copyText('Dorm 待结清汇总：\n' + lines.join('\n'));
      })),
    node('div', {class: 'settle-strip'},
      openPairs.map((pair) => {
        const isMine = viewerId && (pair.debtorId === viewerId || pair.payerId === viewerId);
        return node('div', {class: isMine ? 'settle-item mine' : 'settle-item'},
          node('span', {}, pair.debtor + ' → ' + pair.payer + ' '),
          node('strong', {}, money(pair.total)),
          button('批量结算', () => settlementEditor(pair), 'primary'));
      }))
  ) : null;

  const balances = (data.balances || []).filter((b) => b.active || b.openPayable > 0 || b.openReceivable > 0);
  const balancePanel = balances.length ? node('details', {class: 'panel'},
    node('summary', {}, '成员累计应收 / 应付明细（点击展开）'),
    node('div', {class: 'cards'},
      balances.map((b) => node('article', {class: viewerId === b.id ? 'panel card-body mine' : 'panel card-body'},
        node('strong', {}, b.name + (viewerId === b.id ? '（我）' : '')),
        node('small', {}, '累计应收 ' + money(b.receivable) + ' · 待收 ' + money(b.openReceivable)),
        node('small', {}, '累计应付 ' + money(b.payable) + ' · 待付 ' + money(b.openPayable)))))
  ) : null;

  const table = data.bills.length === 0 ? empty('没有符合条件的账单') :
    node('div', {class: 'panel table'}, node('table', {},
      node('thead', {}, node('tr', {}, ['账单', '付款人', '金额', '待结清', '创建时间'].map((text) => node('th', {scope: 'col'}, text)))),
      node('tbody', {}, data.bills.map((bill) => node('tr', {},
        node('td', {}, button(bill.title, () => billDetails(bill.id), 'name-button')),
        node('td', {}, bill.payer),
        node('td', {}, money(bill.total)),
        node('td', {}, bill.outstanding ? badge(money(bill.outstanding), true) : badge('已结清')),
        node('td', {}, time(bill.createdAt)))))));

  return node('div', {class: 'stack'},
    node('div', {class: 'metrics'},
      metric('账单金额', money(data.total), 'ledger-total'),
      metric('当前待结清', money(data.outstanding)),
      metric('账单数', data.count)),
    settlementPanel,
    balancePanel,
    node('div', {class: 'toolbar'}, search, button('新建账单', () => newBill(null, data.selectAllParticipants), 'primary')),
    table,
    (data.page > 0 || data.hasNext) ? node('div', {class: 'actions'},
      button('上一页', data.page > 0 ? async () => { filters.page--; await render(); } : null),
      node('span', {}, '第 ' + (data.page + 1) + ' 页'),
      button('下一页', data.hasNext ? async () => { filters.page++; await render(); } : null)) : null);
}

function settlementEditor(pair) {
  const expected = Object.fromEntries(pair.charges.map((c) => [c.billId, c.amount]));
  editor('批量结算 · ' + pair.debtor + ' → ' + pair.payer, [
    node('p', {}, '待核销共 ' + pair.charges.length + ' 笔账单，合计 ' + money(pair.total) + '（从最早账单开始自动核销）'),
    node('ul', {}, pair.charges.map((c) => node('li', {}, c.title + '：' + money(c.amount)))),
    label('本次实付金额（元）', input('amount', (pair.total / 100).toFixed(2), {required: true, inputmode: 'decimal', maxlength: 10})),
  ], '确认结算', async (form) => {
    await request('/api/settlement', {
      debtorId: pair.debtorId,
      payerId: pair.payerId,
      expected,
      amount: form.get('amount').trim(),
    });
    message('已完成批量结算');
  });
}

async function newBill(supply, selectAll = true, existing = null) {
  const previous = existing?.bill;
  const shares = new Map((existing?.shares ?? []).map((share) => [share.id, share]));
  const participants = new Set(existing?.participants ?? []);
  const members = (await request('/api/members')).filter(
    (member) => member.active || member.id === previous?.payerId || shares.has(member.id));
  if (!members.length) throw new Error('请先在「寝室成员」中添加室友');
  const amount = {inputmode: 'decimal', maxlength: 10, placeholder: '0.00'};
  const shared = previous ? previous.total - previous.personal : 0;
  const payerLocked = Boolean(existing?.transfers.length);
  const viewerId = getViewerId();
  const defaultPayer = previous?.payerId ?? (members.some((m) => m.id === viewerId) ? viewerId : members[0].id);
  editor(previous ? '编辑账单' : supply ? '记录采购账单' : '新建账单', [
    label('账单名称', input('title', previous?.title ?? (supply ? '采购 ' + supply.name : ''), {required: true, maxlength: 80})),
    label('公共费用（元）', input('shared', shared ? (shared / 100).toFixed(2) : '', amount)),
    payerLocked
      ? node('p', {}, previous.payer + ' 垫付 · 已有实际转账')
      : label('付款人', select('payerId', members.map((m) => [m.id, m.name]), defaultPayer)),
    node('div', {}, node('p', {}, '均摊成员'),
      node('div', {class: 'form-grid'}, members.map((m) =>
        label(m.name, input('participants', m.id, {type: 'checkbox', checked: previous ? participants.has(m.id) : selectAll}))))),
    node('details', {open: previous?.personal > 0}, node('summary', {}, '个人费用（按成员填写）'),
      node('div', {class: 'form-grid'}, members.map((m) => {
        const fee = shares.get(m.id)?.personal;
        return label(m.name, input('fee:' + m.id, fee ? (fee / 100).toFixed(2) : '', amount));
      }))),
  ], '保存账单', (form) => request(previous ? '/api/ledger/edit' : '/api/ledger', {
    id: previous?.id, version: existing?.version,
    title: form.get('title'), shared: form.get('shared').trim(),
    payerId: payerLocked ? previous.payerId : Number(form.get('payerId')),
    participants: form.getAll('participants').map(Number),
    personal: Object.fromEntries(members.map((m) => [m.id, form.get('fee:' + m.id).trim()]).filter(([, value]) => value)),
    supplyId: supply?.id ?? null,
  }));
}

async function billDetails(id) {
  const detail = await request('/api/ledger/' + id);
  const {bill, shares, transfers, activity} = detail;
  openDialog(bill.title, [node('div', {class: 'stack'},
    node('p', {}, bill.payer + ' 垫付 ' + money(bill.total) + ' · 待结清 ' + money(bill.outstanding)),
    node('h3', {}, '成员分摊'),
    ...shares.map((share) => node('div', {class: 'panel card-body'},
      node('strong', {}, share.name + ' · ' + money(share.amount)),
      node('small', {}, '公共 ' + money(share.amount - share.personal) + ' · 个人 ' + money(share.personal)),
      share.id !== bill.payerId && share.amount > share.paid
        ? node('div', {class: 'actions'},
          node('span', {}, '待付 ' + money(share.amount - share.paid)),
          button('登记转账', () => transferEditor(bill, share)))
        : badge(share.id === bill.payerId ? '垫付人' : '已结清'))),
    node('h3', {}, '已登记转账'),
    transfers.length ? node('ul', {}, transfers.map((item) =>
      node('li', {}, item.member + ' · ' + money(item.amount) + ' · ' + time(item.createdAt))))
      : node('p', {class: 'quiet'}, '还没有登记转账'),
    node('h3', {}, '账单修改记录'),
    activity.length ? node('ul', {}, activity.map((entry) => node('li', {},
      node('div', {}, entry.action + ' · 操作设备 · ' + time(entry.createdAt)),
      node('div', {}, entry.detail),
      node('code', {}, entry.deviceCode))))
      : node('p', {class: 'quiet'}, '暂无设备修改记录。'),
    node('div', {class: 'actions'},
      button('复制账单明细', () => {
        const lines = shares
          .filter((s) => s.id !== bill.payerId && s.amount > s.paid)
          .map((s) => s.name + ' → ' + bill.payer + ' ' + money(s.amount - s.paid));
        return copyText(bill.title + '（' + bill.payer + '垫付 ' + money(bill.total) + '）\n' + (lines.length ? lines.join('\n') : '已全部结清'));
      }),
      button('编辑账单', () => newBill(null, true, detail)),
      button('删除账单', () => deleteBill(bill), 'danger-outline')),
  )]);
}

function deleteBill(bill) {
  editor('删除账单', [
    node('p', {}, '将删除「' + bill.title + '」，并从账本和结算统计中移除这笔账的分摊与转账记录。此操作无法在应用内撤销。'),
    button('取消', () => billDetails(bill.id)),
  ], '确认删除', async () => {
    await request('/api/ledger/delete', {id: bill.id});
    filters.page = 0;
    message('已删除账单');
  }, 'danger');
}

function transferEditor(bill, share) {
  editor('登记转账', [
    node('p', {}, share.name + ' → ' + bill.payer),
    label('实际到账金额（元）', input('amount', ((share.amount - share.paid) / 100).toFixed(2), {required: true, inputmode: 'decimal', maxlength: 10})),
  ], '确认登记', (form) => request('/api/transfers', {
    billId: bill.id, memberId: share.id, amount: form.get('amount').trim(),
  }));
}

function choreView(data) {
  const viewerId = getViewerId();
  const viewerName = viewerId ? viewerSelect?.selectedOptions?.[0]?.textContent?.replace(/^我是 /, '') : null;
  const day = input('day', data.day, {type: 'date', min: '1900-01-01', max: '9999-12-31', 'aria-label': '排班日期'});
  day.addEventListener('change', () => {
    if (day.value) { filters.day = day.value; run(render); }
  });
  return node('div', {class: 'stack'},
    node('div', {class: 'toolbar'}, node('div', {class: 'actions'}, day,
      button('今天', async () => { filters.day = ''; await render(); })),
      button('生成至选中日期', async () => {
        await request('/api/chores/generate', {day: data.day});
        await render();
        message('已更新排班');
      }, 'primary')),
    data.shifts.length ? node('div', {class: 'cards'}, data.shifts.map((shift) => {
      const mine = viewerName && shift.member === viewerName;
      return node('section', {class: mine ? 'panel card-body mine' : 'panel card-body'},
        node('h3', {}, shift.title),
        node('p', {}, '值日人 · ' + shift.member + (mine ? '（我）' : '')),
        shift.completedAt
          ? badge('已打卡 · ' + time(shift.completedAt))
          : node('div', {class: 'actions'},
              data.day > data.today
                ? badge('尚未到值日日期')
                : button('完成打卡', async () => {
                    await request('/api/chores/complete', {id: shift.id});
                    await render();
                    message('已完成打卡');
                  }, 'primary'),
              button('换人', () => reassignShiftDialog(shift))));
    })) : empty('当天没有排班。可生成排班或在 Dorm 中配置卫生任务。'));
}

async function reassignShiftDialog(shift) {
  const members = (await request('/api/members')).filter((m) => m.active);
  if (!members.length) throw new Error('没有可用的在用成员');
  editor('改派值日人 · ' + shift.title, [
    node('p', {}, '当前值日人：' + shift.member),
    label('新值日人', select('memberId', members.map((m) => [m.id, m.name]), members[0].id)),
  ], '确认改派', async (form) => {
    await request('/api/chores/reassign', {id: shift.id, memberId: Number(form.get('memberId'))});
    message('已改派值日人');
  });
}

function supplyView(items) {
  const queryText = filters.supplyQuery.trim().toLowerCase();
  const visible = items.filter((item) => {
    if (filters.supplyNeedOnly && item.status === 'stocked') return false;
    if (!queryText) return true;
    return [item.name, item.category, item.location, item.note].some((v) => String(v || '').toLowerCase().includes(queryText));
  });
  const search = node('form', {class: 'actions'},
    input('supplyQuery', filters.supplyQuery, {placeholder: '搜索物资/分类/位置', maxlength: 40}),
    label('仅看采购/缺货', input('needOnly', 'yes', {type: 'checkbox', checked: filters.supplyNeedOnly})),
    node('button', {type: 'submit'}, '筛选'));
  search.addEventListener('submit', (e) => {
    e.preventDefault();
    const form = new FormData(search);
    filters.supplyQuery = form.get('supplyQuery');
    filters.supplyNeedOnly = form.has('needOnly');
    run(render);
  });

  return node('div', {class: 'stack'},
    node('div', {class: 'toolbar'},
      search,
      button('新增物资', () => supplyEditor(), 'primary')),
    visible.length ? node('div', {class: 'cards'}, visible.map((item) =>
      node('section', {class: 'panel card-body'},
        node('h3', {}, item.name),
        node('p', {}, item.category + ' · 库存 ' + item.quantity),
        badge(purchaseStates[item.status] || item.status, item.status === 'needed'),
        item.location ? node('small', {}, '位置 · ' + item.location) : null,
        item.note ? node('p', {}, item.note) : null,
        node('div', {class: 'actions'},
          button('编辑', () => supplyEditor(item)),
          item.status !== 'ordered' ? button('标记采购中', async () => {
            await request('/api/supplies/order', {id: item.id}); await render();
          }) : null,
          button('记采购账单', () => newBill(item)),
          button('补货入库', () => receiveEditor(item), 'primary'),
          button('删除', () => deleteSupplyDialog(item), 'danger-outline')))))
      : empty(items.length ? '没有符合条件的物资' : '还没有物资'));
}

function deleteSupplyDialog(item) {
  editor('删除物资', [
    node('p', {}, '将从物资清单移除「' + item.name + '」。已关联的历史采购账单仍可在公共账本中查询。'),
  ], '确认删除', async () => {
    await request('/api/supplies/delete', {id: item.id});
    message('已删除物资');
  }, 'danger');
}

function supplyEditor(item = {}) {
  editor(item.id ? '编辑物资' : '新增物资', [
    label('名称', input('name', item.name, {required: true, maxlength: 80})),
    label('分类', input('category', item.category, {required: true, maxlength: 40})),
    label('库存', input('quantity', item.quantity ?? 0, {type: 'number', required: true, min: 0, max: 999999})),
    label('存放位置', input('location', item.location, {maxlength: 80})),
    label('采购状态', select('status', Object.entries(purchaseStates), item.status || 'stocked')),
    label('备注', node('textarea', {name: 'note', maxlength: 500, rows: 3}, item.note || '')),
  ], '保存物资', (form) => request('/api/supplies/save', {
    ...Object.fromEntries(form), id: item.id ?? null, quantity: Number(form.get('quantity')),
  }));
}

function receiveEditor(item) {
  editor('补货入库', [
    node('p', {}, item.name + ' · 当前库存 ' + item.quantity),
    label('本次入库数量', input('quantity', '', {type: 'number', required: true, min: 1, max: 999999})),
  ], '确认入库', (form) => request('/api/supplies/receive', {id: item.id, quantity: Number(form.get('quantity'))}));
}

function matterView(items) {
  const viewerId = getViewerId();
  const filtered = items.filter((item) =>
    item.archived === filters.archived &&
    (!filters.onlyMine || !viewerId || item.ownerId === viewerId));
  const toolbar = node('div', {class: 'toolbar'},
    node('div', {class: 'actions'},
      button(filters.archived ? '查看进行中的看板' : '查看归档', async () => {
        filters.archived = !filters.archived; await render();
      }),
      viewerId ? button(filters.onlyMine ? '显示全部事务' : '仅看我负责', async () => {
        filters.onlyMine = !filters.onlyMine; await render();
      }, filters.onlyMine ? 'chip active' : '') : null),
    button('新建事务', () => matterEditor(), 'primary'));
  if (filters.archived) {
    return node('div', {class: 'stack'}, toolbar,
      filtered.length ? node('div', {class: 'cards'}, filtered.map(matterCard)) : empty('没有归档事务'));
  }
  return node('div', {class: 'stack'}, toolbar, node('div', {class: 'lanes'},
    Object.entries(matterStates).map(([key, title]) => {
      const lane = filtered.filter((item) => item.status === key);
      return node('section', {class: 'lane'},
        node('h2', {}, title + ' · ' + lane.length),
        lane.length ? lane.map(matterCard) : empty('暂无事务'));
    })));
}

function matterCard(item) {
  const viewerId = getViewerId();
  const status = select('status', Object.entries(matterStates), item.status);
  status.setAttribute('aria-label', '事务状态');
  status.addEventListener('change', () => run(async () => {
    try { await request('/api/matters/status', {id: item.id, status: status.value}); }
    finally { await render(); }
  }));
  const mine = viewerId && item.ownerId === viewerId;
  return node('article', {class: mine ? 'panel card-body mine' : 'panel card-body'},
    node('h3', {}, item.title),
    item.urgent ? badge('优先处理', true) : null,
    node('small', {}, (item.owner || '未指派') + (mine ? '（我）' : '') + (item.dueDay ? ' · 截止 ' + item.dueDay : '')),
    item.note ? node('p', {}, item.note) : null,
    node('div', {class: 'actions'},
      !item.archived ? status : null,
      !item.archived ? button('编辑', () => matterEditor(item)) : null,
      button(item.archived ? '恢复' : '归档', async () => {
        await request('/api/matters/archive', {id: item.id, archived: !item.archived});
        await render();
      })));
}

async function matterEditor(item = {}) {
  const viewerId = getViewerId();
  const members = (await request('/api/members')).filter((m) => m.active || m.id === item.ownerId);
  const defaultOwner = item.id ? item.ownerId : (members.some((m) => m.id === viewerId) ? viewerId : '');
  editor(item.id ? '编辑事务' : '新建事务', [
    label('事务标题', input('title', item.title, {required: true, maxlength: 80})),
    label('负责人', select('ownerId', [['', '未指派'], ...members.map((m) => [m.id, m.name])], defaultOwner)),
    label('截止日期', input('due', item.dueDay || '', {type: 'date', min: '1900-01-01', max: '9999-12-31'})),
    label('优先处理', input('urgent', 'yes', {type: 'checkbox', checked: item.urgent})),
    label('说明', node('textarea', {name: 'note', maxlength: 600, rows: 4}, item.note || '')),
  ], '保存事务', (form) => request('/api/matters/save', {
    ...Object.fromEntries(form), id: item.id ?? null,
    ownerId: form.get('ownerId') === '' ? null : Number(form.get('ownerId')),
    urgent: form.has('urgent'),
  }));
}

function memberView(members) {
  const viewerId = getViewerId();
  return node('div', {class: 'stack'},
    node('div', {class: 'toolbar'},
      node('p', {class: 'quiet'}, '共 ' + members.length + ' 名成员（' + members.filter((m) => m.active).length + ' 名在用）'),
      button('添加成员', () => memberEditor(), 'primary')),
    members.length ? node('div', {class: 'cards'}, members.map((member) =>
      node('section', {class: viewerId === member.id ? 'panel card-body mine' : 'panel card-body'},
        node('h3', {}, member.name + (viewerId === member.id ? '（我的视角）' : '')),
        member.active ? badge('在用') : badge('已停用', true),
        node('div', {class: 'actions'},
          button('改名', () => memberEditor(member)),
          button(member.active ? '停用' : '启用', async () => {
            await request('/api/members/active', {id: member.id, active: !member.active});
            await render();
            message(member.active ? '已停用成员' : '已启用成员');
          }),
          button('删除', () => deleteMemberDialog(member), 'danger-outline')))))
      : empty('还没有成员，先添加几位室友吧'));
}

function memberEditor(member = {}) {
  editor(member.id ? '编辑成员姓名' : '添加成员', [
    label('成员姓名', input('name', member.name || '', {required: true, maxlength: 40})),
  ], '保存成员', async (form) => {
    await request('/api/members/save', {id: member.id ?? null, name: form.get('name')});
    message(member.id ? '已更新成员姓名' : '已添加成员');
  });
}

function deleteMemberDialog(member) {
  editor('删除成员', [
    node('p', {}, '将永久删除成员「' + member.name + '」及与其相关的未完成排班。若该成员已有未删除账单或已打卡卫生记录，请改用「停用」。'),
  ], '确认删除', async () => {
    await request('/api/members/delete', {id: member.id});
    message('已删除成员');
  }, 'danger');
}

setInterval(() => {
  if (!document.hidden && !dialog.open && current !== 'tools' && !content.contains(document.activeElement)) {
    run(render);
  }
}, 20000);
run(render);
