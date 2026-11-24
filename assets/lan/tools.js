'use strict';

(function () {
  const penaltyStorageKey = 'dorm-web-penalties';
  const toolState = {
    penaltyOptions: loadPenaltyOptions(),
    tab: 'draw',
    bombMax: 100,
    bombLow: 1,
    bombHigh: 100,
    bombSecret: 0,
    bombExploded: false,
    bombHistory: [],
    bombPenalty: null,
    drawCount: 1,
    teamCount: 2,
    drawResult: null,
    rollResult: '点击下方按钮掷骰子或抛硬币',
  };

  function randomInt(maxExclusive) {
    const arr = new Uint32Array(1);
    crypto.getRandomValues(arr);
    return arr[0] % maxExclusive;
  }

  function resetBomb(maxLimit) {
    toolState.bombMax = maxLimit;
    toolState.bombLow = 1;
    toolState.bombHigh = maxLimit;
    toolState.bombSecret = 1 + randomInt(maxLimit);
    toolState.bombExploded = false;
    toolState.bombHistory = [];
    toolState.bombPenalty = null;
  }

  resetBomb(100);

  function uniqueLines(text) {
    const seen = new Set();
    for (const line of String(text || '').split('\n')) {
      const cleaned = line.trim();
      if (cleaned) seen.add(cleaned);
    }
    return [...seen];
  }

  function loadPenaltyOptions() {
    try {
      return uniqueLines(localStorage.getItem(penaltyStorageKey));
    } catch (_) {
      return [];
    }
  }

  function shuffle(list) {
    const copy = [...list];
    for (let i = copy.length - 1; i > 0; i--) {
      const j = randomInt(i + 1);
      [copy[i], copy[j]] = [copy[j], copy[i]];
    }
    return copy;
  }


  const groupColors = ['#6de6cf', '#8eb8ff', '#ffb27d', '#c9adff', '#ddeb88', '#ff9ac0', '#79dbff', '#f7db97'];
  const groupPhase = (time, from, to) => Math.min(1, Math.max(0, (time - from) / (to - from)));
  const smooth = (fraction) => fraction * fraction * (3 - 2 * fraction);

  function makeGroupScene(groups, roster) {
    const count = Math.min(groupColors.length, groups.length);
    const pads = Array.from({length: count}, (_, index) => {
      const first = Math.floor(index * groups.length / count);
      const end = Math.floor((index + 1) * groups.length / count);
      const members = groups.slice(first, end).flat();
      const size = roster.length <= 18 ? 1 : Math.ceil(members.length / 3);
      const batches = [];
      for (let start = 0; start < members.length; start += size) {
        batches.push(members.slice(start, start + size));
      }
      return {label: first + 1 === end ? String(end) : (first + 1) + '–' + end, count: members.length, batches};
    });
    const packets = [];
    for (let round = 0; round < Math.max(...pads.map(pad => pad.batches.length)); round++) {
      for (const [pad, entry] of pads.entries()) {
        const members = entry.batches[round];
        if (members) packets.push({pad, size: members.length, name: members[0]});
      }
    }
    const source = [...packets].sort((a, b) => roster.indexOf(a.name) - roster.indexOf(b.name));
    return {pads, packets, source, started: performance.now(), duration: 2200 + Math.min(360, packets.length * 16)};
  }

  function groupResults(result, active, helpers) {
    const {node, button, copyText, rerender} = helpers;
    const {groups, scene} = result;
    const total = groups.reduce((sum, group) => sum + group.length, 0);
    const finish = () => {
      result.finished = true;
      rerender();
    };
    const progress = node('progress', {max: total, value: 0, 'aria-label': '分组进度'});
    const counter = node('small', {}, '已入组 0 / ' + total + ' 人');
    let stage;
    if (scene) {
      const pads = scene.pads.map((entry, index) => {
        const marker = node('div', {class: 'group-marker'});
        marker.style.setProperty('--pad-color', groupColors[index]);
        const count = node('span', {}, '0/' + entry.count);
        marker.append(node('b', {}, entry.label), count);
        return {marker, count};
      });
      const labels = active ? scene.packets.map(packet =>
        node('span', {class: 'group-packet'}, packet.size > 1 ? '+' + packet.size : packet.name)) : [];
      const space = node('div', {class: 'group-space'},
        node('div', {class: 'group-grid'}), pads.map(pad => pad.marker), labels);
      stage = node('div', {class: 'group-stage', 'aria-hidden': 'true', 'data-settled': active ? null : 'true'}, space);
      const orbit = (slot, time, unit) => {
        const angle = 2 * Math.PI * slot / scene.packets.length + 1.55 * Math.PI * smooth(groupPhase(time, 0, .66));
        return [
          Math.sin(angle) * unit * (1.35 + 1.36 * smooth(groupPhase(time, 0, .22))),
          (Math.sin(angle * 2 + slot * .9) * .26 - .98) * unit,
          Math.cos(angle) * unit * 1.35,
        ];
      };
      const place = (element, [x, y, z], extra = '') => {
        element.style.transform = 'translate3d(' + x + 'px,' + y + 'px,' + z + 'px) translate(-50%,-50%) ' + extra;
      };
      const render = (stamp) => {
        if (!stage.isConnected) return;
        const moving = active && !result.finished && !matchMedia('(prefers-reduced-motion: reduce)').matches;
        const time = moving ? groupPhase(stamp, scene.started, scene.started + scene.duration) : 1;
        const unit = Math.min(stage.clientWidth / 8.4, stage.clientHeight / 5.5);
        const target = pads.map((pad, index) => {
          const split = pads.length <= 4 ? pads.length : Math.floor(pads.length / 2);
          const front = index >= split;
          const columns = front ? pads.length - split : split;
          return [
            ((front ? index - split : index) - (columns - 1) / 2) * 1.78 * unit,
            (pads.length > 4 && !front ? 1.02 : 1.87) * unit,
            (pads.length > 4 && !front ? -.78 : 1.1) * unit,
          ];
        });
        const landed = pads.map(() => 0);
        scene.packets.forEach((packet, index) => {
          const spread = .42 * index / Math.max(1, scene.packets.length - 1);
          const leave = .25 + spread;
          const arrival = .49 + spread;
          const label = labels[index];
          if (time >= arrival) {
            landed[packet.pad] += packet.size;
            if (label) label.hidden = true;
            return;
          }
          const slot = scene.source.indexOf(packet);
          const position = orbit(slot, Math.min(time, leave), unit);
          const flight = smooth(groupPhase(time, leave, arrival));
          const endpoint = target[packet.pad];
          const arc = Math.sin(Math.PI * flight);
          const point = position.map((value, axis) => value + (endpoint[axis] - value) * flight);
          point[1] -= .62 * unit * arc;
          point[2] += .4 * unit * arc;
          place(label, point, 'scale(' + (1 - .58 * flight ** 2) + ')');
          if (time >= leave) label.style.borderColor = groupColors[packet.pad];
        });
        pads.forEach(({marker, count}, index) => {
          marker.style.width = (1.54 * unit) + 'px';
          marker.style.height = Math.max(20, .70 * unit) + 'px';
          place(marker, target[index]);
          count.textContent = landed[index] + '/' + scene.pads[index].count;
          marker.classList.toggle('landed', landed[index] > 0);
        });
        const done = landed.reduce((sum, value) => sum + value, 0);
        if (progress.value !== done) {
          progress.value = done;
          counter.textContent = '已入组 ' + done + ' / ' + total + ' 人';
        }
        if (moving && time < 1) requestAnimationFrame(render);
        else if (active) finish();
      };
      requestAnimationFrame(render);
      // A fresh render on resize keeps the settled 3D scene aligned.
      if (!active && typeof ResizeObserver === 'function') {
        const observer = new ResizeObserver(() => {
          if (stage.isConnected) render(performance.now());
          else observer.disconnect();
        });
        observer.observe(stage);
      }
    }
    const results = node('div', {class: 'group-results'},
      groups.map((group, index) => node('div', {class: 'group-result'},
        node('b', {}, '第 ' + (index + 1) + ' 组'),
        node('span', {}, group.join('、')))));
    return node('div', {class: 'result-banner'},
      node('div', {class: 'actions'}, node('b', {role: 'status'}, active ? '正在分配成员' : '分组结果'),
        active ? button('跳过动画', finish) : node('small', {}, total + ' 人 · ' + groups.length + ' 组')),
      stage,
      active ? [progress, counter] : [
        results,
        node('div', {class: 'actions'}, button('复制分组', () =>
          copyText(groups.map((group, i) => '第' + (i + 1) + '组：' + group.join('、')).join('\n')))),
      ]);
  }

  window.dormToolsView = function dormToolsView(data, helpers) {
    const {node, button, input, badge, message, openDialog, dialog, copyText, rerender} = helpers;
    const tabs = [
      ['draw', '快速抽签'],
      ['teams', '随机分组'],
      ['roll', '骰子与硬币'],
      ['bomb', '数字炸弹'],
    ];

    const tabBar = node('div', {class: 'chip-row'},
      tabs.map(([id, text]) => button(text, () => {
        toolState.tab = id;
        rerender();
      }, toolState.tab === id ? 'chip active' : 'chip'))
    );

    if (toolState.tab === 'bomb') {
      const rangeBar = node('div', {class: 'chip-row'},
        [50, 100, 200].map((limit) => button('1 ~ ' + limit, () => {
          resetBomb(limit);
          rerender();
        }, toolState.bombMax === limit ? 'chip active' : 'chip'))
      );

      const guessInput = input('guess', '', {
        type: 'number',
        min: toolState.bombLow,
        max: toolState.bombHigh,
        placeholder: '输入 ' + toolState.bombLow + ' ~ ' + toolState.bombHigh + ' 的整数',
      });
      const submitGuess = () => {
        const val = Number(guessInput.value.trim());
        if (!Number.isInteger(val) || val < toolState.bombLow || val > toolState.bombHigh) {
          message('请输入 ' + toolState.bombLow + ' 至 ' + toolState.bombHigh + ' 之间的整数');
          return;
        }
        if (val === toolState.bombSecret) {
          toolState.bombExploded = true;
          toolState.bombHistory.unshift(val + ' 💥');
        } else if (val < toolState.bombSecret) {
          toolState.bombLow = val + 1;
          toolState.bombHistory.unshift(val + ' ↑');
        } else {
          toolState.bombHigh = val - 1;
          toolState.bombHistory.unshift(val + ' ↓');
        }
        rerender();
        if (matchMedia('(pointer: fine)').matches && !toolState.bombExploded) {
          document.querySelector('input[name="guess"]')?.focus();
        }
      };
      const form = node('form', {class: 'actions'}, guessInput, node('button', {type: 'submit', class: 'primary'}, '报数'));
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        submitGuess();
      });

      const defaults = data.penalties?.length ? data.penalties : ['承包今天寝室倒垃圾'];
      const penalties = toolState.penaltyOptions.length ? toolState.penaltyOptions : defaults;
      function editPenalties() {
        const area = node('textarea', {rows: 7}, penalties.join('\n'));
        const error = node('small', {class: 'error', role: 'alert'});
        function applyOptions(options) {
          toolState.penaltyOptions = options;
          let saved = true;
          try {
            if (options.length) localStorage.setItem(penaltyStorageKey, options.join('\n'));
            else localStorage.removeItem(penaltyStorageKey);
          } catch (_) {
            saved = false;
          }
          dialog.close();
          rerender();
          if (!saved) message('当前浏览器无法长期保存名单');
        }
        openDialog('编辑惩罚', [
          node('div', {class: 'stack'},
            node('label', {}, '每行一项惩罚', area),
            node('small', {}, '空行和重复项会自动忽略'),
            error,
            node('div', {class: 'actions'},
              button('保存', () => {
                const options = uniqueLines(area.value);
                if (!options.length) {
                  error.textContent = '请至少填写一项惩罚';
                  area.focus();
                  return;
                }
                applyOptions(options);
              }, 'primary'),
              button('恢复默认', () => applyOptions([]))))
        ]);
      }
      return node('div', {class: 'stack'},
        tabBar,
        node('section', {class: 'panel card-body'},
          node('div', {class: 'actions'},
            node('h3', {}, '数字炸弹'),
            button('编辑惩罚', editPenalties)),
          node('small', {}, '室友轮流报数缩窄安全区间，踩中炸弹数字的人抽一个轻惩罚！'),
          rangeBar,
          node('div', {class: toolState.bombExploded ? 'result-banner boom' : 'result-banner'},
            node('small', {}, toolState.bombExploded ? '炸弹已引爆' : '当前安全范围'),
            node('strong', {}, toolState.bombExploded
              ? ('💥 炸弹数字：' + toolState.bombSecret + '（共 ' + toolState.bombHistory.length + ' 轮）')
              : (toolState.bombLow + '  ~  ' + toolState.bombHigh))
          ),
          !toolState.bombExploded ? form : node('div', {class: 'actions'},
            button('抽个轻惩罚', () => {
              toolState.bombPenalty = penalties[randomInt(penalties.length)];
              rerender();
            }, 'primary'),
            button('再来一局', () => {
              resetBomb(toolState.bombMax);
              rerender();
            })),
          toolState.bombPenalty ? node('div', {class: 'panel'},
            node('strong', {}, '本局惩罚：' + toolState.bombPenalty)
          ) : null,
          toolState.bombHistory.length ? node('div', {class: 'chip-row'},
            toolState.bombHistory.slice(0, 12).map((item) => badge(item, item.includes('💥')))
          ) : null
        )
      );
    }

    if (toolState.tab === 'draw' || toolState.tab === 'teams') {
      const roster = data.members.length ? data.members : ['室友甲', '室友乙', '室友丙', '室友丁'];
      const isTeams = toolState.tab === 'teams';
      const count = isTeams ? toolState.teamCount : toolState.drawCount;
      const teamResult = isTeams && toolState.drawResult?.kind === 'teams' ? toolState.drawResult : null;
      const active = Boolean(teamResult?.scene && !teamResult.finished &&
        performance.now() < teamResult.scene.started + teamResult.scene.duration);
      const runDraw = () => {
        if (active) return;
        const min = isTeams ? 2 : 1;
        if (roster.length < min || count < min || count > roster.length) {
          message('候选项人数与抽取数量不匹配');
          return;
        }
        const pool = shuffle(roster);
        if (isTeams) {
          const groups = Array.from({length: count}, () => []);
          pool.forEach((member, idx) => groups[idx % count].push(member));
          const motion = !matchMedia('(prefers-reduced-motion: reduce)').matches &&
            document.documentElement.dataset.eink !== 'true';
          toolState.drawResult = {kind: 'teams', groups, scene: motion ? makeGroupScene(groups, roster) : null};
        } else {
          toolState.drawResult = {kind: 'draw', picked: pool.slice(0, count)};
        }
        rerender();
        if (matchMedia('(pointer: fine)').matches && !toolState.bombExploded) {
          document.querySelector('input[name="guess"]')?.focus();
        }
      };
      return node('div', {class: 'stack'},
        tabBar,
        node('section', {class: 'panel card-body'},
          node('h3', {}, isTeams ? '随机分组（当前在用室友）' : '快速抽签（当前在用室友）'),
          node('div', {class: 'chip-row'}, roster.map((m) => badge(m))),
          node('div', {class: 'actions'},
            node('span', {}, isTeams ? '分几组：' : '抽几人：'),
            button('-', active ? null : () => {
              const min = isTeams ? 2 : 1;
              if (count > min) {
                if (isTeams) toolState.teamCount--;
                else toolState.drawCount--;
                rerender();
              }
            }),
            node('strong', {}, String(count)),
            button('+', active ? null : () => {
              if (count < roster.length) {
                if (isTeams) toolState.teamCount++;
                else toolState.drawCount++;
                rerender();
              }
            }),
            button(isTeams ? (active ? '分组中…' : (teamResult ? '重新分组' : '开始分组')) : '开始抽签',
              active ? null : runDraw, 'primary')),
          teamResult ? groupResults(teamResult, active, helpers) :
          toolState.drawResult?.kind === 'draw' && !isTeams
            ? node('div', {class: 'result-banner'},
                node('small', {}, '抽中成员'),
                node('strong', {}, toolState.drawResult.picked.join('、')),
                button('复制结果', () => copyText('抽签结果：' + toolState.drawResult.picked.join('、'))))
            : null
        )
      );
    }

    return node('div', {class: 'stack'},
      tabBar,
      node('section', {class: 'panel card-body'},
        node('h3', {}, '骰子与硬币'),
        node('div', {class: 'result-banner'},
          node('small', {}, '随机结果'),
          node('strong', {}, toolState.rollResult)
        ),
        node('div', {class: 'actions'},
          button('掷 1 颗骰子', () => {
            toolState.rollResult = '🎲 骰子结果：' + (1 + randomInt(6)) + ' 点';
            rerender();
          }, 'primary'),
          button('掷 2 颗骰子', () => {
            const a = 1 + randomInt(6);
            const b = 1 + randomInt(6);
            toolState.rollResult = '🎲 双骰结果：' + a + ' + ' + b + ' = ' + (a + b) + ' 点';
            rerender();
          }),
          button('抛硬币', () => {
            toolState.rollResult = '🪙 硬币结果：' + (randomInt(2) === 0 ? '正面' : '反面');
            rerender();
          }))
      )
    );
  };
})();
