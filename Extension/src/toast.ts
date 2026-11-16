// 页面上的一句提示：底部居中的一枚玻璃胶囊。位置、淡入淡出（0.3 秒）、停留时长（3 秒）、底色都和 App 里的提示一样；
// 多一个小记号，因为这里有「正在收」这一段等待，App 的提示没有。
// 这个函数会被整段注入到网页里执行，所以不能引用外面的任何东西

export function toast(text: string, state: 'busy' | 'done' | 'fail') {
  const TAG = 'piyi-toast'
  let host = document.querySelector(TAG) as (HTMLElement & { timer?: number }) | null
  if (!host) {
    host = document.createElement(TAG)
    const root = host.attachShadow({ mode: 'open' })
    root.innerHTML = `
      <style>
        :host { all: initial; position: fixed; inset: auto 0 28px 0; display: flex; justify-content: center; z-index: 2147483647; pointer-events: none; }
        .pill {
          display: flex; align-items: center; gap: 8px; padding: 9px 16px 9px 13px; border-radius: 999px;
          font: 500 13px/18px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; letter-spacing: .01em;
          color: rgb(28 28 26); background: rgb(251 250 248 / .72); border: .5px solid rgb(0 0 0 / .08);
          box-shadow: 0 10px 30px rgb(0 0 0 / .12), 0 1px 2px rgb(0 0 0 / .06);
          backdrop-filter: blur(24px) saturate(180%); -webkit-backdrop-filter: blur(24px) saturate(180%);
          opacity: 0; transition: opacity .3s ease-out;
        }
        .pill.shown { opacity: 1; }
        @media (prefers-color-scheme: dark) {
          .pill { color: rgb(245 244 240); background: rgb(22 22 20 / .72); border-color: rgb(255 255 255 / .1); }
        }
        .mark { width: 14px; height: 14px; flex: none; }
        .spin { animation: spin .8s linear infinite; }
        @keyframes spin { to { transform: rotate(360deg) } }
        .draw { stroke-dasharray: 20; stroke-dashoffset: 20; animation: draw .35s .05s ease-out forwards; }
        @keyframes draw { to { stroke-dashoffset: 0 } }
      </style>
      <div class="pill"><svg class="mark" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"></svg><span></span></div>`
    document.documentElement.append(host)
  }
  const root = host.shadowRoot!
  const pill = root.querySelector('.pill')!, mark = root.querySelector('svg')!
  root.querySelector('span')!.textContent = text
  mark.innerHTML = {
    busy: '<circle cx="7" cy="7" r="5.5" stroke-opacity=".25"/><path class="spin" style="transform-origin:7px 7px" d="M7 1.5a5.5 5.5 0 0 1 5.5 5.5"/>',
    done: '<path class="draw" d="M2.8 7.4l2.8 2.8 5.6-6.2"/>',
    fail: '<path d="M7 3.6v4.2"/><circle cx="7" cy="10.6" r=".4" fill="currentColor"/>',
  }[state]
  requestAnimationFrame(() => pill.classList.add('shown'))
  clearTimeout(host.timer)
  if (state === 'busy') return
  const current = host
  current.timer = window.setTimeout(() => {
    pill.classList.remove('shown')
    setTimeout(() => current.remove(), 300)
  }, 3000)
}
