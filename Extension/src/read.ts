// 注入到网页里：读出渲染完的整页 HTML，交回 App 去解析（App 用和直接下载时同一套解析）。
// 后台抓取时先等脚本把页面画完、需要的话滚到底让懒加载的内容出来；你点「收进拼贴」时页面就在眼前，直接读。

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

/// 页面加载完不等于内容到了：靠脚本渲染的页面要等 DOM 安静下来
function quiet(ms: number, limit: number) {
  return new Promise<void>(resolve => {
    let timer = setTimeout(done, ms)
    const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, ms) })
    const deadline = setTimeout(done, limit)
    function done() {
      observer.disconnect()
      clearTimeout(timer)
      clearTimeout(deadline)
      resolve()
    }
    observer.observe(document, { childList: true, subtree: true, characterData: true })
  })
}

/// 滚到底：高度连续两次不变就停，最多 20 次（看不见的网页定时器一秒一次，再多就太慢了）
async function scrollToBottom() {
  let height = 0
  for (let steady = 0, round = 0; steady < 2 && round < 20; round++) {
    window.scrollTo(0, document.documentElement.scrollHeight)
    await sleep(500)
    const next = document.documentElement.scrollHeight
    steady = next === height ? steady + 1 : 0
    height = next
  }
  window.scrollTo(0, 0)
}

async function collageRead(options: { settle: boolean; scroll: boolean }) {
  if (options.settle) await quiet(800, 8000)
  if (options.scroll) await scrollToBottom()
  return { url: location.href, html: document.documentElement.outerHTML }
}

;(globalThis as any).collageRead = collageRead
