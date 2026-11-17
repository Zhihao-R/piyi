// Extension background: connects to the relay as soon as it starts and keeps the connection open (the browser won't suspend the background while a connection is open).
// It does three things:
// 1. Click the toolbar icon to collect the current page into Piyi; right-click a web page and choose "Collect to Piyi" to collect the image you right-clicked, the selected text, or the whole page;
// 2. When the App needs to read a page that requires sign-in or loads with scripts, it opens a tab in a persistent minimized window and reads it there;
// 3. When the App needs to call an API that requires sign-in (Bilibili subtitle URLs), it makes the request with the browser's sign-in state, without opening a tab.
import { HOST, type Message } from './wire'
import { toast } from './toast'

/** Interface text: picks the _locales entry matching the browser language */
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
    setTimeout(connect, 5000)  // this is lost when the background is shut down; the alarm below covers that
  })
  port.postMessage({ type: 'hello', version } satisfies Message)
  return port
}

function onMessage(message: Message) {
  switch (message.type) {
    case 'reload': return chrome.runtime.reload()  // the App installed a new version
    case 'fetch': return void answer(message)
    case 'request': return void request(message)
    case 'collected': return acks.get(message.id!)?.(message)
  }
}

// MARK: Collect to Piyi

/// Waits for a reply, matched by the collect ID. Two replies in turn: the relay says it's saved in the inbox, the App says it has checked for duplicates. They supply the text to show (say); this only shows it
const acks = new Map<string, (reply: Message | null) => void>()

function reply(id: string, limit: number) {
  return new Promise<Message | null>(resolve => {
    acks.set(id, resolve)
    setTimeout(() => resolve(null), limit)
  }).finally(() => acks.delete(id))
}

/// The context menu has a single item; where you right-click decides what to collect: on an image, that image; otherwise the selected text if any; otherwise the whole page
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

/// take returns what to send to Piyi: the whole page, the selected text, or an image
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
  // url is the page it's on: recorded as the source when collecting an image or text
  connect().postMessage({ type: 'collect', id, url: tab.url, ...content } satisfies Message)
  const ack = await saved
  if (!ack) return say(t('notConnected'), 'fail')
  if (ack.ok === false) return say(ack.say ?? t('notSaved'), 'fail')
  if (ack.queued) return say(ack.say ?? t('savedQueued'), 'done')
  // By now it's in Piyi's inbox and won't be lost; wait for the App to check for duplicates and say what was collected and whether it was already there. If it doesn't reply for a while, the item is still in the inbox
  const verdict = await reply(id, 8000)
  await say(verdict?.say ?? t('savedLater'), verdict?.ok === false ? 'fail' : 'done')
}

function page(tabId: number): Promise<Partial<Message>> {
  return read(tabId, { settle: false, scroll: false }).catch(() => { throw new Error(t('unreadable')) })
}

/// Reads the selected text from the page: the copy the browser passes with the right-click drops line breaks, so it's only a fallback when reading fails
async function selection(tabId: number, frameId: number, given: string): Promise<Partial<Message>> {
  const injections = await chrome.scripting.executeScript({ target: { tabId, frameIds: [frameId] }, func: () => getSelection()?.toString() ?? '' }).catch(() => [])
  return { text: injections[0]?.result || given }
}

/// The largest image to fetch: even with base64 overhead, it stays within the browser's per-message limit to the relay (64 MB)
const IMAGE_LIMIT = 32 * 1024 * 1024
/// Each image fetch numbers its own rule: when two images are collected back to back, each keeps its own and they don't replace each other
let lastRule = 0

/// Images are fetched here: with the browser's sign-in state and the page as the source, so image hosts' hotlink protection lets them through. If it can't be fetched (or is too large), only the URL is passed and the App downloads it
async function image(src: string, from: string): Promise<Partial<Message>> {
  const bytes = await imageBytes(src, from).catch(() => null)
  if (bytes) return { image: bytes }
  if (!/^https?:/.test(src)) throw new Error(t('imageUnavailable'))  // images the page generates on the fly (blob:) are gone once you leave the page
  return { imageURL: src }
}

async function imageBytes(src: string, from: string) {
  const rule = ++lastRule
  // Requests from the background carry no source by default: add a rule that applies only to this URL and only to the background's own requests, setting the source (Referer) to the page, and remove it once done
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
  }).catch(() => {})  // if the rule wasn't added, fetch without a source; most image hosts still serve it
  try {
    const response = await fetch(src, { credentials: 'include', signal: AbortSignal.timeout(REQUEST_LIMIT) })
    const blob = await response.blob()
    // when blocked, what comes back is usually an explanation page, not an image
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

/// When the page can't show a toast (the browser's own pages), mark the icon instead
function flag(text: string) {
  chrome.action.setBadgeBackgroundColor({ color: '#1c1c1a' })
  chrome.action.setBadgeText({ text: '!' })
  chrome.action.setTitle({ title: text })
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' })
    chrome.action.setTitle({ title: t('collect') })
  }, 2500)
}

// MARK: Reading web pages for the App

/// The longest a page may take to read. The App sends one at a time and waits 75 seconds, longer than this: the timeout is reported here first, and the tab is closed here too
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

/// The longest a request may wait. The App waits 20 seconds, longer than this: the timeout is reported here first
const REQUEST_LIMIT = 15_000

/// The extension has permission for all sites, so requests from the background carry that site's sign-in state (cookies)
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
    // It may still redirect after loading (sign-in checks, short links); when the injected page is replaced, try again
    const attempt = async () => {
      await loaded(tabId)
      return read(tabId, { settle: true, scroll })
    }
    return await Promise.race([attempt().catch(attempt), timeout])
  } finally {
    clearTimeout(timer)
    // Close it on timeout too: once the tab closes, any loading and reading still pending in it fails and ends, rather than dragging into the next page
    await chrome.tabs.remove(tabId).catch(() => {})  // you may have closed it already
  }
}

async function openTab(url: string) {
  const create = async () => chrome.tabs.create({ windowId: await readerWindow(), url, active: true })
  return create().catch(async () => {
    // The window was just closed by the idle alarm: open a new one
    await chrome.storage.session.remove('reader')
    return create()
  })
}

async function read(tabId: number, options: { settle: boolean; scroll: boolean }) {
  await chrome.scripting.executeScript({ target: { tabId }, files: ['read.js'] })
  const [injection] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (options) => (globalThis as any).piyiRead(options),
    args: [options],
  })
  return injection.result as { url: string; html: string }
}

/// Waits for the tab to finish loading; fails if the tab is closed (timeout, or you closed it)
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

// MARK: Persistent minimized window

/// All fetches open tabs in this one window, which only flashes on the first fetch. It closes after a few idle minutes rather than staying in the Dock
const READER_IDLE_MINUTES = 5
const READER_PAGE = chrome.runtime.getURL('reader.html')

async function readerWindow(): Promise<number> {
  chrome.alarms.clear('close-reader')
  const { reader } = await chrome.storage.session.get('reader')
  const existing = reader ? await chrome.windows.get(reader as number).catch(() => null) : null
  if (existing) {
    // You opened it: minimize it again
    if (existing.state !== 'minimized') await chrome.windows.update(existing.id!, { state: 'minimized' })
    return existing.id!
  }
  // On macOS the browser ignores minimized at creation and the window pops up full size, so it has to be minimized again right after: it shows on screen for under half a second
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

/// The background was shut down midway: close tabs left half-read in the window, keeping only the explanation page
async function tidyReader() {
  const { reader } = await chrome.storage.session.get('reader')
  if (!reader) return
  const tabs = await chrome.tabs.query({ windowId: reader as number }).catch(() => [])
  for (const tab of tabs) if (tab.url !== READER_PAGE && tab.id) await chrome.tabs.remove(tab.id).catch(() => {})
}

chrome.alarms.onAlarm.addListener(alarm => {
  // Every fetch cancels the close-window alarm, so if it fires, the window has been idle the whole time
  if (alarm.name === 'close-reader') closeReader()
  else connect()
})

chrome.runtime.onStartup.addListener(connect)
chrome.runtime.onInstalled.addListener(connect)
chrome.alarms.create('reconnect', { periodInMinutes: 1 })
tidyReader()
connect()
