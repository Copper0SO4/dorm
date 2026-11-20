'use strict';

const byId = (id) => document.getElementById(id);
const content = byId('content');
const dialog = byId('dialog');
const sections = {
  ledger: ['公共账本', '查看账单和成员分摊，记录新的开销与实际转账。'],
  chores: ['卫生排班', '查看每天的值日安排和打卡记录。'],
  supplies: ['公共物资', '管理库存、采购状态与补货。'],
  matters: ['寝室事务', '跟进报修、活动准备和其他共同事项。'],
};
const purchaseStates = {stocked: '已入库', needed: '待采购', ordered: '采购中'};
const matterStates = {open: '待处理', doing: '进行中', done: '已完成'};
const filters = {query: '', unpaid: false, page: 0, day: '', archived: false};
let current = 'ledger';
let token = '';
let renderId = 0;
let toastTimer;

try { token = sessionStorage.getItem('dormLanSession') || ''; } catch (_) {}

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

async function run(action) {
  try { await action(); } catch (error) { message(error.message); }
}

function endSession(text = '') {
  token = '';
  renderId++;
  try { sessionStorage.removeItem('dormLanSession'); } catch (_) {}
  if (dialog.open) dialog.close();
  byId('app').hidden = true;
  byId('connect').hidden = false;
  byId('pair-error').textContent = text;
}

async function request(path, data, pairing = false) {
  let response;
  try {
    response = await fetch(path, {
      method: data === undefined ? 'GET' : 'POST',
      headers: {
        ...(data === undefined ? {} : {'Content-Type': 'application/json'}),
        ...(token && !pairing ? {'Authorization': 'Bearer ' + token} : {}),
      },
      body: data === undefined ? undefined : JSON.stringify(data),
      cache: 'no-store',
    });
  } catch (_) {
    throw new Error('连接服务器失败。请检查 Dorm 是否仍在运行。');
  }
  const result = await response.json();
  if (response.status === 401 && !pairing) endSession('会话已失效，请重新输入访问码。');
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
const badge = (text, warning = false) => node('span', {class: warning ? 'badge warn' : 'badge'}, text);
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

async function openApp() {
  byId('connect').hidden = true;
  byId('app').hidden = false;
  await render();
}

byId('pair').addEventListener('submit', async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const submit = form.querySelector('button');
  if (submit.disabled) return;
  submit.disabled = true;
  byId('pair-error').textContent = '';
  try {
    const result = await request('/api/session', {code: new FormData(form).get('code')}, true);
    token = result.token;
    try { sessionStorage.setItem('dormLanSession', token); } catch (_) {}
    form.reset();
    await openApp();
  } catch (error) {
    endSession(error.message);
  } finally {
    submit.disabled = false;
  }
});
byId('logout').addEventListener('click', () => endSession());
byId('refresh').addEventListener('click', () => run(render));
byId('dialog-close').addEventListener('click', () => dialog.close());
document.querySelectorAll('[data-section]').forEach((item) => {
  item.addEventListener('click', () => {
    current = item.dataset.section;
    content.replaceChildren(empty('正在读取数据…'));
    run(render);
  });
});

async function render() {
  if (!token) return;
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
  const data = await request('/api/' + section + '?' + params);
  if (id !== renderId || !token) return;
  const view = {ledger: ledgerView, chores: choreView, supplies: supplyView, matters: matterView}[section];
  content.replaceChildren(view(data));
}

function ledgerView(data) {
  const search = node('form', {},
    input('query', filters.query, {placeholder: '搜索账单或付款人', 'aria-label': '搜索账单', maxlength: 80}),
    label('仅待结清', input('unpaid', 'yes', {type: 'checkbox', checked: filters.unpaid})),
    node('button', {type: 'submit'}, '筛选'));
  search.addEventListener('submit', (event) => {
    event.preventDefault();
    const input = new FormData(search);
    filters.query = input.get('query');
    filters.unpaid = input.has('unpaid');
    filters.page = 0;
    run(render);
  });
  const metric = (caption, value, extra = '') => node('article', {class: 'metric ' + extra}, node('small', {}, caption), node('strong', {}, value));
  const table = data.bills.length === 0 ? empty('没有符合条件的账单') :
    node('div', {class: 'panel table'}, node('table', {},
      node('thead', {}, node('tr', {}, ['账单', '付款人', '金额', '待结清', '创建时间'].map(text => node('th', {scope: 'col'}, text)))),
      node('tbody', {}, data.bills.map(bill => node('tr', {},
        node('td', {}, button(bill.title, () => billDetails(bill.id), 'name-button')),
        node('td', {}, bill.payer), node('td', {}, money(bill.total)),
        node('td', {}, bill.outstanding ? badge(money(bill.outstanding), true) : badge('已结清')),
        node('td', {}, time(bill.createdAt)))))));
  return node('div', {class: 'stack'},
    node('div', {class: 'metrics'},
      metric('账单金额', money(data.total), 'ledger-total'),
      metric('当前待结清', money(data.outstanding)),
      metric('账单数', data.count)),
    node('div', {class: 'toolbar'}, search, button('新建账单', () => newBill(null, data.selectAllParticipants), 'primary')),
    table,
    (data.page > 0 || data.hasNext) ? node('div', {class: 'actions'},
      button('上一页', data.page > 0 ? async () => { filters.page--; await render(); } : null),
      node('span', {}, '第 ' + (data.page + 1) + ' 页'),
      button('下一页', data.hasNext ? async () => { filters.page++; await render(); } : null)) : null);
}

async function newBill(supply, selectAll = true) {
  const members = (await request('/api/members')).filter(member => member.active);
  if (!members.length) throw new Error('请先在 Dorm 中添加寝室成员');
  const amount = {inputmode: 'decimal', maxlength: 10, placeholder: '0.00'};
  editor(supply ? '记录采购账单' : '新建账单', [
    label('账单名称', input('title', supply ? '采购 ' + supply.name : '', {required: true, maxlength: 80})),
    label('公共费用（元）', input('shared', '', amount)),
    label('付款人', select('payerId', members.map(m => [m.id, m.name]), members[0].id)),
    node('div', {}, node('p', {}, '均摊成员'),
      node('div', {class: 'form-grid'}, members.map(m =>
        label(m.name, input('participants', m.id, {type: 'checkbox', checked: selectAll}))))),
    node('details', {}, node('summary', {}, '个人费用（按成员填写）'),
      node('div', {class: 'form-grid'}, members.map(m => label(m.name, input('fee:' + m.id, '', amount))))),
  ], '保存账单', (form) => request('/api/ledger', {
    title: form.get('title'), shared: form.get('shared').trim(), payerId: Number(form.get('payerId')),
    participants: form.getAll('participants').map(Number),
    personal: Object.fromEntries(members.map(m => [m.id, form.get('fee:' + m.id).trim()]).filter(([, value]) => value)),
    supplyId: supply?.id ?? null,
  }));
}

async function billDetails(id) {
  const {bill, shares, transfers} = await request('/api/ledger/' + id);
  openDialog(bill.title, [node('div', {class: 'stack'},
    node('p', {}, bill.payer + ' 垫付 ' + money(bill.total) + ' · 待结清 ' + money(bill.outstanding)),
    node('h3', {}, '成员分摊'),
    ...shares.map(share => node('div', {class: 'panel card-body'},
      node('strong', {}, share.name + ' · ' + money(share.amount)),
      node('small', {}, '公共 ' + money(share.amount - share.personal) + ' · 个人 ' + money(share.personal)),
      share.id !== bill.payerId && share.amount > share.paid
        ? node('div', {class: 'actions'},
          node('span', {}, '待付 ' + money(share.amount - share.paid)),
          button('登记转账', () => transferEditor(bill, share)))
        : badge(share.id === bill.payerId ? '垫付人' : '已结清'))),
    node('h3', {}, '已登记转账'),
    transfers.length ? node('ul', {}, transfers.map(item =>
      node('li', {}, item.member + ' · ' + money(item.amount) + ' · ' + time(item.createdAt))))
      : node('p', {class: 'quiet'}, '还没有登记转账'),
    node('div', {class: 'actions'}, button('删除账单', () => deleteBill(bill), 'danger-outline')),
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
  ], '确认登记', form => request('/api/transfers', {
    billId: bill.id, memberId: share.id, amount: form.get('amount').trim(),
  }));
}

function choreView(data) {
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
    data.shifts.length ? node('div', {class: 'cards'}, data.shifts.map(shift =>
      node('section', {class: 'panel card-body'},
        node('h3', {}, shift.title), node('p', {}, '值日人 · ' + shift.member),
        shift.completedAt ? badge('已打卡 · ' + time(shift.completedAt)) :
          data.day > data.today ? badge('尚未到值日日期')
            : button('完成打卡', async () => {
              await request('/api/chores/complete', {id: shift.id});
              await render();
              message('已完成打卡');
            }, 'primary')))) : empty('当天没有排班。可生成排班或在 Dorm 中配置卫生任务。'));
}

function supplyView(items) {
  return node('div', {class: 'stack'},
    node('div', {class: 'toolbar'}, node('p', {class: 'quiet'}, items.length + ' 项物资'),
      button('新增物资', () => supplyEditor(), 'primary')),
    items.length ? node('div', {class: 'cards'}, items.map(item =>
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
          button('补货入库', () => receiveEditor(item), 'primary')))))
      : empty('还没有物资'));
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
  ], '确认入库', form => request('/api/supplies/receive', {id: item.id, quantity: Number(form.get('quantity'))}));
}

function matterView(items) {
  const filtered = items.filter(item => item.archived === filters.archived);
  const toolbar = node('div', {class: 'toolbar'},
    button(filters.archived ? '查看进行中的看板' : '查看归档', async () => {
      filters.archived = !filters.archived; await render();
    }),
    button('新建事务', () => matterEditor(), 'primary'));
  if (filters.archived) return node('div', {class: 'stack'}, toolbar,
    filtered.length ? node('div', {class: 'cards'}, filtered.map(matterCard)) : empty('没有归档事务'));
  return node('div', {class: 'stack'}, toolbar, node('div', {class: 'lanes'},
    Object.entries(matterStates).map(([key, title]) => {
      const lane = filtered.filter(item => item.status === key);
      return node('section', {class: 'lane'},
        node('h2', {}, title + ' · ' + lane.length),
        lane.length ? lane.map(matterCard) : empty('暂无事务'));
    })));
}

function matterCard(item) {
  const status = select('status', Object.entries(matterStates), item.status);
  status.setAttribute('aria-label', '事务状态');
  status.addEventListener('change', () => run(async () => {
    try { await request('/api/matters/status', {id: item.id, status: status.value}); }
    finally { await render(); }
  }));
  return node('article', {class: 'panel card-body'},
    node('h3', {}, item.title),
    item.urgent ? badge('优先处理', true) : null,
    node('small', {}, (item.owner || '未指派') + (item.dueDay ? ' · 截止 ' + item.dueDay : '')),
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
  const members = (await request('/api/members')).filter(m => m.active || m.id === item.ownerId);
  editor(item.id ? '编辑事务' : '新建事务', [
    label('事务标题', input('title', item.title, {required: true, maxlength: 80})),
    label('负责人', select('ownerId', [['', '未指派'], ...members.map(m => [m.id, m.name])], item.ownerId)),
    label('截止日期', input('due', item.dueDay || '', {type: 'date', min: '1900-01-01', max: '9999-12-31'})),
    label('优先处理', input('urgent', 'yes', {type: 'checkbox', checked: item.urgent})),
    label('说明', node('textarea', {name: 'note', maxlength: 600, rows: 4}, item.note || '')),
  ], '保存事务', form => request('/api/matters/save', {
    ...Object.fromEntries(form), id: item.id ?? null,
    ownerId: form.get('ownerId') === '' ? null : Number(form.get('ownerId')),
    urgent: form.has('urgent'),
  }));
}

setInterval(() => {
  if (token && !document.hidden && !dialog.open && !content.contains(document.activeElement)) run(render);
}, 20000);
if (token) run(openApp);
