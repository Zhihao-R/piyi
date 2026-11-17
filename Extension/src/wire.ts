// Messages exchanged with the App: fields match Message in Sources/Wire/Wire.swift

export type Kind = 'hello' | 'fetch' | 'request' | 'result' | 'collect' | 'collected' | 'reload'

export interface Message {
  type: Kind
  id?: string
  url?: string
  html?: string
  /// A passage of text selected on the page
  text?: string
  /// The image itself, base64
  image?: string
  /// The image's URL, when the image itself couldn't be fetched
  imageURL?: string
  body?: string
  ok?: boolean
  error?: string
  scroll?: boolean
  version?: string
  queued?: boolean
  /// A sentence for people to read, shown as is
  say?: string
}

/// The relay's registered name, matching the registration file the App writes into the browser's directory
export const HOST = 'io.github.zhihao_r.piyi.relay'
