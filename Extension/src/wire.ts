// 和 App 之间的消息：字段和 Sources/Wire/Wire.swift 里的 Message 一致

export type Kind = 'hello' | 'fetch' | 'request' | 'result' | 'collect' | 'collected' | 'reload'

export interface Message {
  type: Kind
  id?: string
  url?: string
  html?: string
  /// 网页上选中的一段话
  text?: string
  /// 图片本身，base64
  image?: string
  /// 没取到图片本身时，图片的地址
  imageURL?: string
  body?: string
  ok?: boolean
  error?: string
  scroll?: boolean
  version?: string
  queued?: boolean
  /// 给人看的一句话，原样显示
  say?: string
}

/// 中转程序的登记名，和 App 写进浏览器目录的登记文件一致
export const HOST = 'io.github.zhihao_r.piyi.relay'
