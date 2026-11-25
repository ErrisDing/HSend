import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export function encode(s: string): Uint8Array {
  return s.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(s);
}
export function decode(b: Uint8Array): string {
  return b.length === 0 ? '' : util.TextDecoder.create('utf-8').decodeWithStream(b);
}

export interface HttpHead {
  line: string;
  headers: Map<string,string>;
}

export interface HttpWire {
  send(data: ArrayBuffer): Promise<void>;
  close(): Promise<void>;
  listen(data: (part: Uint8Array) => void, end: () => void, error: () => void): void;
}

class SocketWire implements HttpWire {
  private socket: socket.TLSSocket | socket.TLSSocketConnection;
  constructor(wire: socket.TLSSocket | socket.TLSSocketConnection) { this.socket = wire; }
  send(data: ArrayBuffer): Promise<void> { return this.socket.send(data); }
  close(): Promise<void> { return this.socket.close(); }
  listen(data: (part: Uint8Array) => void, end: () => void, error: () => void): void {
    this.socket.on('message',(event: socket.SocketMessageInfo) => data(new Uint8Array(event.message)));
    this.socket.on('close',end);
    this.socket.on('error',error);
  }
}

export class HttpConnection {
  private wire: HttpWire;
  private queue: Uint8Array[] = [];
  private available: number = 0;
  private ended: boolean = false;
  private closing?: Promise<void>;
  private wake: () => void = () => {};
  onEnd: () => void = () => {};

  static fromSocket(wire: socket.TLSSocket | socket.TLSSocketConnection): HttpConnection {
    return new HttpConnection(new SocketWire(wire));
  }

  constructor(wire: HttpWire) {
    this.wire = wire;
    wire.listen((part: Uint8Array) => {
      if (this.ended || part.byteLength === 0) return;
      this.available += part.byteLength;
      if (this.available > 16 * 1024 * 1024) { this.close(); return; }
      this.queue.push(part);
      this.wake();
    }, () => this.finish(), () => this.close());
  }

  private finish(): void {
    if (this.ended) return;
    this.ended = true;
    this.wake();
    this.onEnd();
  }

  close(): Promise<void> {
    this.finish();
    if (!this.closing) this.closing = this.wire.close().catch(() => {});
    return this.closing;
  }

  async write(data: Uint8Array): Promise<void> {
    if (this.ended) throw new Error('连接已结束');
    await this.wire.send(data.buffer.slice(data.byteOffset,data.byteOffset + data.byteLength));
  }

  async take(max: number): Promise<Uint8Array> {
    while (this.queue.length === 0) {
      if (this.ended) throw new Error('对端已断开');
      await new Promise<void>((resolve,reject) => {
        const timer = setTimeout(() => { this.close(); reject(new Error('等待数据超时')); }, 120000);
        this.wake = () => { clearTimeout(timer); resolve(); };
      });
    }
    const first = this.queue[0];
    const n = Math.min(first.length, max);
    if (n === first.length) this.queue.shift();
    else this.queue[0] = first.subarray(n);
    this.available -= n;
    return first.subarray(0,n);
  }

  private async line(limit: number): Promise<string> {
    const bytes: number[] = [];
    while (bytes.length <= limit) {
      const next = (await this.take(1))[0];
      if (next === 10) {
        if (bytes.pop() !== 13) throw new Error('HTTP 行结束符无效');
        return decode(new Uint8Array(bytes));
      }
      bytes.push(next);
    }
    throw new Error('HTTP 行过长');
  }

  async head(): Promise<HttpHead> {
    const line = await this.line(8192);
    const headers = new Map<string,string>();
    let total = line.length;
    while (total < 32768) {
      const field = await this.line(8192);
      if (field === '') return {line,headers};
      total += field.length + 2;
      const colon = field.indexOf(':');
      if (colon < 1) throw new Error('HTTP 字段无效');
      const name = field.slice(0,colon).trim().toLowerCase();
      if (headers.has(name) && (name === 'content-length' || name === 'transfer-encoding')) throw new Error('重复长度字段');
      headers.set(name,field.slice(colon+1).trim());
    }
    throw new Error('HTTP 头过长');
  }

  async body(head: HttpHead, limit: number, consume: (chunk: Uint8Array) => void): Promise<number> {
    let count = 0;
    const transfer = head.headers.get('transfer-encoding');
    const length = head.headers.get('content-length');
    const chunked = transfer?.toLowerCase() === 'chunked';
    if (transfer && (!chunked || length !== undefined)) throw new Error('正文编码无效');
    do {
      const value = chunked ? (await this.line(1024)).split(';')[0] : (length ?? '0');
      if (!(chunked ? /^[0-9a-f]+$/i : /^[0-9]+$/).test(value)) throw new Error('正文长度无效');
      let left = Number.parseInt(value,chunked ? 16 : 10);
      if (!Number.isSafeInteger(left) || left > limit - count) throw new Error('正文超过声明大小');
      if (chunked && left === 0) {
        let trailers = 0;
        while (trailers < 8192) {
          const trailer = await this.line(8192);
          if (!trailer) return count;
          trailers += trailer.length + 2;
        }
        throw new Error('HTTP 尾部过长');
      }
      while (left > 0) {
        const chunk = await this.take(Math.min(left,65536));
        consume(chunk);
        count += chunk.length;
        left -= chunk.length;
      }
      if (chunked && (await this.line(2)) !== '') throw new Error('分块无效');
    } while (chunked);
    return count;
  }

  async text(head: HttpHead): Promise<string> {
    const chunks: Uint8Array[] = [];
    const length = await this.body(head,1024*1024,(part: Uint8Array) => { chunks.push(part); });
    const out = new Uint8Array(length);
    let offset = 0;
    for (const part of chunks) { out.set(part,offset); offset += part.length; }
    return decode(out);
  }

  async request(path: string, host: string, length: number, json: boolean): Promise<void> {
    await this.write(encode('POST ' + path + ' HTTP/1.1\r\nHost: ' + host + '\r\nConnection: keep-alive\r\nContent-Type: ' +
      (json ? 'application/json' : 'application/octet-stream') + '\r\nContent-Length: ' + length + '\r\n\r\n'));
  }

  async respond(status: number, body: string = ''): Promise<void> {
    const bytes = encode(body);
    await this.write(encode('HTTP/1.1 ' + status + ' ' + (status === 200 ? 'OK' : 'Response') +
      '\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ' + bytes.length + '\r\n\r\n'));
    if (bytes.length) await this.write(bytes);
  }
}
