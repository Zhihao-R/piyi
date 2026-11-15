// 后台读取窗口里那句说明：按浏览器语言显示
document.title = chrome.i18n.getMessage('readerTitle')
document.querySelector('#line1')!.textContent = chrome.i18n.getMessage('readerLine1')
document.querySelector('#line2')!.textContent = chrome.i18n.getMessage('readerLine2')
