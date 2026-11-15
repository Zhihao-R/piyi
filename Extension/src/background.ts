// 扩展后台：一启动就连上中转程序并一直保持连接（连接开着时浏览器不会让后台休眠）。
// 做三件事：
// 1. 你点工具栏上的图标，把眼前这个页面收进拼贴；在网页上右键「收进拼贴」，收右键的那张图、选中的那段话，或者整页；
// 2. App 要读一个需要登录、靠脚本加载的网页时，在一个常驻的最小化窗口里开标签页读出来；
// 3. App 要调一个要登录的接口时（B 站的字幕地址），带着浏览器里的登录状态请求，不开标签页。
import { HOST, type Message } from './wire'
import { toast } from './toast'

/** 界面文字：按浏览器语言取 _locales 里的那一份 */
const t = (key: string, ...subs: string[]) => chrome.i18n.getMessage(key, subs)

const version = chrome.runtime.getManifest().version_name ?? chrome.runtime.getManifest().version

let port: chrome.runtime.Port | null = null

function connect() {
  if (port) return port
  port = chrome.runtime.connectNative(HOST)
  port.onMessage.addListener(onMessage)
  port.onDisconnect.addListener(() => {
    port = null
    for (const settle of acks.values()) settle(null)
    acks.clear()
    setTimeout(connect, 5000)  // 后台被回收时这个会丢，由下面的闹钟兜底
  })
  port.postMessage({ type: 'hello', version } satisfies Message)
  return port
}

function onMessage(message: Message) {
  switch (message.type) {
    case 'reload': return chrome.runtime.reload()  // App 装了新版
    case 'fetch': return void answer(message)
    case 'request': return void request(message)
    case 'collected': return acks.get(message.id!)?.(message)
  }
}

// MARK: 收进拼贴

/// 等一声回话，按收集的编号对上。先后两声：中转程序说存进收件箱了，App 说查过重了。要显示的话都由它们给（say），这里只管显示
const acks = new Map<string, (reply: Message | null) => void>()

function reply(id: string, limit: number) {
  return new Promise<Message | null>(resolve => {
    acks.set(id, resolve)
    setTimeout(() => resolve(null), limit)
  }).finally(() => acks.delete(id))
}

/// 右键菜单只有一项，由右键的位置决定收什么：落在图上收这张图，否则有选中的文字收这段话，否则收整页
const MENU = 'collect'
chrome.contextMenus.removeAll(() => chrome.contextMenus.create({
  id: MENU, title: t('collect'), contexts: ['page', 'frame', 'selection', 'link', 'editable', 'image', 'video', 'audio'],
}))

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MENU) return
  if (info.mediaType === 'image' && info.srcUrl) return collect(tab, (_, from) => image(info.srcUrl!, from))
  if (info.selectionText) return collect(tab, tabId => selection(tabId, info.frameId ?? 0, info.selectionText!))
  return collect(tab, page)
})

chrome.action.onClicked.addListener(tab => collect(tab, page))

/// take 交回要发给拼贴的内容：整页、选中的话，或者一张图
async function collect(tab: chrome.tabs.Tab | undefined, take: (tabId: number, page: string) => Promise<Partial<Message>>) {
  if (!tab?.id || !/^https?:/.test(tab.url ?? '')) return flag(t('cannotCollectPage'))
  const tabId = tab.id
  const say = (text: string, state: 'busy' | 'done' | 'fail') =>
    chrome.scripting.executeScript({ target: { tabId }, func: toast, args: [text, state] }).catch(() => flag(text))
  await say(t('collecting'), 'busy')
  let content: Partial<Message>
  try {
    content = await take(tabId, tab.url!)
  } catch (error) {
    return say((error as Error).message, 'fail')
  }
  const id = crypto.randomUUID()
  const saved = reply(id, 4000)
  // url 是所在的网页：收图、收文字时记作出处
  connect().postMessage({ type: 'collect', id, url: tab.url, ...content } satisfies Message)
  const ack = await saved
  if (!ack) return say(t('notConnected'), 'fail')
  if (ack.ok === false) return say(ack.say ?? t('notSaved'), 'fail')
  if (ack.queued) return say(ack.say ?? t('savedQueued'), 'done')
  // 到这里已经落在拼贴的收件箱里，不会丢；等 App 查过重，说收下的是什么、是不是收过。它一时没回话，东西也在收件箱里
  const verdict = await reply(id, 8000)
  await say(verdict?.say ?? t('savedLater'), verdict?.ok === false ? 'fail' : 'done')
}

function page(tabId: number): Promise<Partial<Message>> {
  return read(tabId, { settle: false, scroll: false }).catch(() => { throw new Error(t('unreadable')) })
}

/// 选中的文字从页面里读：浏览器随右键给的那份会丢掉换行，它只作读不到时的退路
async function selection(tabId: number, frameId: number, given: string): Promise<Partial<Message>> {
  const injections = await chrome.scripting.executeScript({ target: { tabId, frameIds: [frameId] }, func: () => getSelection()?.toString() ?? '' }).catch(() => [])
  return { text: injections[0]?.result || given }
}

/// 图片最大取这么多：再加上 base64 的膨胀，仍在浏览器发给中转程序的单条上限（64 MB）以内
const IMAGE_LIMIT = 32 * 1024 * 1024
/// 每次取图用自己的规则编号：连着收两张图时各管各的，不互相顶掉
let lastRule = 0

/// 图片在这里取：带着浏览器里的登录状态，来源写成所在的网页，图床的防盗链才放行。取不到（或者太大）就只交地址，由 App 去下载
async function image(src: string, from: string): Promise<Partial<Message>> {
  const bytes = await imageBytes(src, from).catch(() => null)
  if (bytes) return { image: bytes }
  if (!/^https?:/.test(src)) throw new Error(t('imageUnavailable'))  // 页面临时生成的图（blob:）离开页面就没有了
  return { imageURL: src }
}

async function imageBytes(src: string, from: string) {
  const rule = ++lastRule
  // 后台发的请求本来不带来源：加一条只管这个地址、只管后台自己的请求的规则，把来源（Referer）写成所在的网页，取完就撤
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: [rule],
    addRules: [{
      id: rule,
      action: {
        type: chrome.declarativeNetRequest.RuleActionType.MODIFY_HEADERS,
        requestHeaders: [{ header: 'Referer', operation: chrome.declarativeNetRequest.HeaderOperation.SET, value: from }],
      },
      condition: { urlFilter: '|' + src, tabIds: [chrome.tabs.TAB_ID_NONE], resourceTypes: [chrome.declarativeNetRequest.ResourceType.XMLHTTPREQUEST] },
    }],
  }).catch(() => {})  // 规则没加上就不带来源去取，多数图床也给
  try {
    const response = await fetch(src, { credentials: 'include', signal: AbortSignal.timeout(REQUEST_LIMIT) })
    const blob = await response.blob()
    // 被拦下时回来的常是一页说明，不是图
    if (!response.ok || !blob.type.startsWith('image/') || blob.size > IMAGE_LIMIT) return null
    const url = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(reader.result as string)
      reader.onerror = () => reject(reader.error)
      reader.readAsDataURL(blob)
    })
    return url.slice(url.indexOf(',') + 1)
  } finally {
    chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [rule] }).catch(() => {})
  }
}

/// 页面里放不了提示时（浏览器自己的页面），在图标上标一下
function flag(text: string) {
  chrome.action.setBadgeBackgroundColor({ color: '#1c1c1a' })
  chrome.action.setBadgeText({ text: '!' })
  chrome.action.setTitle({ title: text })
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' })
    chrome.action.setTitle({ title: t('collect') })
  }, 2500)
}

// MARK: 替 App 读网页

/// 一页最多读这么久。App 那边一次只发一个、等 75 秒，比这里长：超时由这里先报，标签页也由这里关
const READ_LIMIT = 60_000

async function answer(request: Message) {
  try {
    const page = await fetchPage(request.url!, request.scroll ?? true)
    port?.postMessage({ type: 'result', id: request.id, ok: true, ...page } satisfies Message)
  } catch (error) {
    port?.postMessage({ type: 'result', id: request.id, ok: false, error: (error as Error)?.message ?? String(error) } satisfies Message)
  }
  chrome.alarms.create('close-reader', { delayInMinutes: READER_IDLE_MINUTES })
}

/// 一次请求最多等这么久。App 那边等 20 秒，比这里长：超时由这里先报
const REQUEST_LIMIT = 15_000

/// 扩展有全部网站的权限，后台发的请求会带上这个网站的登录状态（Cookie）
async function request(message: Message) {
  try {
    const response = await fetch(message.url!, { credentials: 'include', signal: AbortSignal.timeout(REQUEST_LIMIT) })
    if (!response.ok) throw new Error(t('siteError', String(response.status)))
    port?.postMessage({ type: 'result', id: message.id, ok: true, body: await response.text() } satisfies Message)
  } catch (error) {
    port?.postMessage({ type: 'result', id: message.id, ok: false, error: (error as Error)?.message ?? String(error) } satisfies Message)
  }
}

async function fetchPage(url: string, scroll: boolean) {
  const tabId = (await openTab(url)).id!
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(t('readTimeout'))), READ_LIMIT) })
  try {
    // 加载完之后还可能跳转（登录检查、短链），注入的页面被换掉时再来一次
    const attempt = async () => {
      await loaded(tabId)
      return read(tabId, { settle: true, scroll })
    }
    return await Promise.race([attempt().catch(attempt), timeout])
  } finally {
    clearTimeout(timer)
    // 超时也关：标签页一关，里面还在等的加载和读取都跟着失败结束，不会拖到下一页
    await chrome.tabs.remove(tabId).catch(() => {})  // 你可能已经手动关掉了
  }
}

async function openTab(url: string) {
  const create = async () => chrome.tabs.create({ windowId: await readerWindow(), url, active: true })
  return create().catch(async () => {
    // 窗口刚好被闲置的闹钟关掉了：重开一个
    await chrome.storage.session.remove('reader')
    return create()
  })
}

async function read(tabId: number, options: { settle: boolean; scroll: boolean }) {
  await chrome.scripting.executeScript({ target: { tabId }, files: ['read.js'] })
  const [injection] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (options) => (globalThis as any).collageRead(options),
    args: [options],
  })
  return injection.result as { url: string; html: string }
}

/// 等标签页加载完；标签页被关掉（超时、你手动关）就失败
function loaded(tabId: number) {
  return new Promise<void>((resolve, reject) => {
    const updated = (id: number, change: chrome.tabs.OnUpdatedInfo) => { if (id === tabId && change.status === 'complete') done() }
    const removed = (id: number) => { if (id === tabId) done(new Error(t('tabClosed'))) }
    function done(error?: Error) {
      chrome.tabs.onUpdated.removeListener(updated)
      chrome.tabs.onRemoved.removeListener(removed)
      error ? reject(error) : resolve()
    }
    chrome.tabs.onUpdated.addListener(updated)
    chrome.tabs.onRemoved.addListener(removed)
    chrome.tabs.get(tabId).then(tab => tab.status === 'complete' && done(), () => done(new Error(t('tabClosed'))))
  })
}

// MARK: 常驻的最小化窗口

/// 抓取都在这一个窗口里开标签页，窗口只在第一次抓取时闪一下。闲了几分钟就关掉，不一直占着程序坞
const READER_IDLE_MINUTES = 5
const READER_PAGE = chrome.runtime.getURL('reader.html')

async function readerWindow(): Promise<number> {
  chrome.alarms.clear('close-reader')
  const { reader } = await chrome.storage.session.get('reader')
  const existing = reader ? await chrome.windows.get(reader as number).catch(() => null) : null
  if (existing) {
    // 你把它点开过：缩回去
    if (existing.state !== 'minimized') await chrome.windows.update(existing.id!, { state: 'minimized' })
    return existing.id!
  }
  // macOS 上浏览器不理会创建时的 minimized，窗口照样全屏弹出来，只能创建后马上再缩一次：屏幕上闪不到半秒
  const window = (await chrome.windows.create({ url: READER_PAGE, state: 'minimized', focused: false }))!
  await chrome.windows.update(window.id!, { state: 'minimized' })
  await chrome.storage.session.set({ reader: window.id })
  return window.id!
}

async function closeReader() {
  const { reader } = await chrome.storage.session.get('reader')
  if (reader) await chrome.windows.remove(reader as number).catch(() => {})
  await chrome.storage.session.remove('reader')
}

/// 后台中途被回收：窗口里读到一半的标签页关掉，只留说明页
async function tidyReader() {
  const { reader } = await chrome.storage.session.get('reader')
  if (!reader) return
  const tabs = await chrome.tabs.query({ windowId: reader as number }).catch(() => [])
  for (const tab of tabs) if (tab.url !== READER_PAGE && tab.id) await chrome.tabs.remove(tab.id).catch(() => {})
}

chrome.alarms.onAlarm.addListener(alarm => {
  // 每次开始抓取都会取消关窗口的闹钟，响了就说明这几分钟一直闲着
  if (alarm.name === 'close-reader') closeReader()
  else connect()
})

chrome.runtime.onStartup.addListener(connect)
chrome.runtime.onInstalled.addListener(connect)
chrome.alarms.create('reconnect', { periodInMinutes: 1 })
tidyReader()
connect()
