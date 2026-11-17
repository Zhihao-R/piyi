// Injected into web pages: reads the fully rendered page HTML and hands it back to the App to parse (the App uses the same parser as for direct downloads).
// For background fetches, first wait for scripts to finish drawing the page and, if needed, scroll to the bottom so lazy-loaded content appears; when you click "Collect to Piyi" the page is already in front of you, so read it right away.

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

/// A loaded page doesn't mean the content is there: for script-rendered pages, wait until the DOM settles
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

/// Scroll to the bottom: stop once the height stays the same twice in a row, at most 20 times (timers on hidden pages run once a second, so more would be too slow)
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

async function piyiRead(options: { settle: boolean; scroll: boolean }) {
  if (options.settle) await quiet(800, 8000)
  if (options.scroll) await scrollToBottom()
  return { url: location.href, html: document.documentElement.outerHTML }
}

;(globalThis as any).piyiRead = piyiRead
