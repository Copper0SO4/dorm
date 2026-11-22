'use strict';

(function () {
  const penaltyStorageKey = 'dorm-web-penalties';
  const toolState = {
    penaltyOptions: loadPenaltyOptions(),
    tab: 'decide',
    presetId: null,
    customOptions: {},
    spinning: false,
    spinTimer: null,
    litIndex: -1,
    decisionResult: null,
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

  window.dormToolsView = function dormToolsView(data, helpers) {
    const {node, button, input, badge, message, openDialog, dialog, copyText, rerender} = helpers;
    const presets = data.presets || [];
    if (!toolState.presetId && presets.length) toolState.presetId = presets[0].id;
    const activePreset = presets.find((p) => p.id === toolState.presetId) || presets[0];

    function presetOptions(preset) {
      if (!preset) return [];
      if (toolState.customOptions[preset.id]) return toolState.customOptions[preset.id];
      if (preset.usesMembers) {
        return data.members.length ? data.members : ['室友甲', '室友乙', '室友丙'];
      }
      return preset.options;
    }

    const tabs = [
      ['decide', '决策盲盒'],
      ['bomb', '数字炸弹'],
      ['draw', '快速抽签'],
      ['teams', '随机分组'],
      ['roll', '骰子与硬币'],
    ];

    const tabBar = node('div', {class: 'chip-row'},
      tabs.map(([id, text]) => button(text, () => {
        if (toolState.spinning) return;
        toolState.tab = id;
        rerender();
      }, toolState.tab === id ? 'chip active' : 'chip'))
    );

    if (toolState.tab === 'decide') {
      const options = presetOptions(activePreset);
      const presetBar = node('div', {class: 'chip-row'},
        presets.map((p) => button(p.title, () => {
          if (toolState.spinning) return;
          toolState.presetId = p.id;
          toolState.litIndex = -1;
          toolState.decisionResult = null;
          rerender();
        }, p.id === activePreset?.id ? 'chip active' : 'chip'))
      );

      const pills = node('div', {class: 'chip-row'},
        options.map((item, idx) =>
          node('span', {class: idx === toolState.litIndex ? 'option-pill lit' : 'option-pill'}, item))
      );

      const startSpin = () => {
        if (toolState.spinning) return;
        if (!options.length) {
          message('请至少保留 1 个有效选项');
          return;
        }
        const chosenIndex = randomInt(options.length);
        const chosen = options[chosenIndex];
        if (options.length === 1) {
          toolState.litIndex = 0;
          toolState.decisionResult = chosen;
          rerender();
          return;
        }
        clearInterval(toolState.spinTimer);
        toolState.spinning = true;
        toolState.decisionResult = null;
        toolState.litIndex = randomInt(options.length);
        let step = 0;
        rerender();
        toolState.spinTimer = setInterval(() => {
          step++;
          if (step >= 11) {
            clearInterval(toolState.spinTimer);
            toolState.spinning = false;
            toolState.litIndex = chosenIndex;
            toolState.decisionResult = chosen;
            rerender();
          } else {
            toolState.litIndex = (toolState.litIndex + 1) % options.length;
            rerender();
          }
        }, 85);
      };

      const editCustom = () => {
        const area = node('textarea', {rows: 7, maxlength: 2000}, options.join('\n'));
        const save = button('保存选项', () => {
          const parsed = uniqueLines(area.value);
          if (!parsed.length) {
            message('请至少输入 1 个选项');
            return;
          }
          toolState.customOptions[activePreset.id] = parsed;
          toolState.litIndex = -1;
          toolState.decisionResult = null;
          dialog.close();
          rerender();
        }, 'primary');
        const resetDefault = button('恢复默认', () => {
          delete toolState.customOptions[activePreset.id];
          toolState.litIndex = -1;
          toolState.decisionResult = null;
          dialog.close();
          rerender();
        });
        openDialog('编辑「' + activePreset.title + '」选项', [
          node('div', {class: 'stack'},
            node('small', {}, '每行一个候选项，自动去重'),
            area,
            node('div', {class: 'actions'}, save, resetDefault))
        ]);
      };

      return node('div', {class: 'stack'},
        tabBar,
        node('section', {class: 'panel card-body'},
          node('h3', {}, '寝室决策盲盒 · ' + (activePreset?.title || '')),
          node('small', {}, activePreset?.description || ''),
          presetBar,
          pills,
          toolState.decisionResult ? node('div', {class: 'result-banner'},
            node('small', {}, activePreset.title + ' · 抽中结果'),
            node('strong', {}, toolState.decisionResult),
            node('div', {class: 'actions'},
              button('复制结果', () => copyText(activePreset.title + '：' + toolState.decisionResult)))
          ) : null,
          node('div', {class: 'actions'},
            button(toolState.spinning ? '抽取中…' : '帮我们决定', toolState.spinning ? null : startSpin, 'primary'),
            button('编辑选项', toolState.spinning ? null : editCustom))
        )
      );
    }

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
      const runDraw = () => {
        const min = isTeams ? 2 : 1;
        if (roster.length < min || count < min || count > roster.length) {
          message('候选项人数与抽取数量不匹配');
          return;
        }
        const pool = shuffle(roster);
        if (isTeams) {
          const groups = Array.from({length: count}, () => []);
          pool.forEach((member, idx) => groups[idx % count].push(member));
          toolState.drawResult = {kind: 'teams', groups};
        } else {
          toolState.drawResult = {kind: 'draw', picked: pool.slice(0, count)};
        }
        rerender();
      };
      return node('div', {class: 'stack'},
        tabBar,
        node('section', {class: 'panel card-body'},
          node('h3', {}, isTeams ? '随机分组（当前在用室友）' : '快速抽签（当前在用室友）'),
          node('div', {class: 'chip-row'}, roster.map((m) => badge(m))),
          node('div', {class: 'actions'},
            node('span', {}, isTeams ? '分几组：' : '抽几人：'),
            button('-', () => {
              const min = isTeams ? 2 : 1;
              if (count > min) {
                if (isTeams) toolState.teamCount--;
                else toolState.drawCount--;
                rerender();
              }
            }),
            node('strong', {}, String(count)),
            button('+', () => {
              if (count < roster.length) {
                if (isTeams) toolState.teamCount++;
                else toolState.drawCount++;
                rerender();
              }
            }),
            button(isTeams ? '开始分组' : '开始抽签', runDraw, 'primary')),
          toolState.drawResult && toolState.drawResult.kind === toolState.tab
            ? node('div', {class: 'result-banner'},
                toolState.drawResult.kind === 'draw'
                  ? [
                      node('small', {}, '抽中成员'),
                      node('strong', {}, toolState.drawResult.picked.join('、')),
                      button('复制结果', () => copyText('抽签结果：' + toolState.drawResult.picked.join('、'))),
                    ]
                  : [
                      node('small', {}, '分组结果'),
                      ...toolState.drawResult.groups.map((g, i) => node('div', {}, '第 ' + (i + 1) + ' 组：' + g.join('、'))),
                      button('复制分组', () => copyText(toolState.drawResult.groups.map((g, i) => '第' + (i + 1) + '组：' + g.join('、')).join('\n'))),
                    ])
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
          button('掷 6 面骰子', () => {
            toolState.rollResult = '🎲 骰子结果：' + (1 + randomInt(6)) + ' 点';
            rerender();
          }, 'primary'),
          button('抛硬币', () => {
            toolState.rollResult = '🪙 硬币结果：' + (randomInt(2) === 0 ? '正面' : '反面');
            rerender();
          }))
      )
    );
  };
})();
