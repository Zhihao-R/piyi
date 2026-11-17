// The explanation shown in the background reading window: displayed in the browser language
document.title = chrome.i18n.getMessage('readerTitle')
document.querySelector('#line1')!.textContent = chrome.i18n.getMessage('readerLine1')
document.querySelector('#line2')!.textContent = chrome.i18n.getMessage('readerLine2')
