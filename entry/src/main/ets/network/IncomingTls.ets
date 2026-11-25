import { TlsStream, wantWrite } from 'libhsend_tls.so';
import { HttpWire } from './HttpConnection';
import { fingerprint } from './Identity';

export class IncomingTls implements HttpWire {
  private stream: TlsStream;
  private sinceYield: number = 0;
  constructor(stream: TlsStream) { this.stream = stream; }

  async authenticate(): Promise<string> {
    const timer = setTimeout(() => this.stream.close(), 10000);
    try {
      let rc = this.stream.handshake();
      while (rc !== 0) {
        await this.stream.wait(rc === wantWrite);
        rc = this.stream.handshake();
      }
      const der = this.stream.peerCertificate();
      return der.byteLength ? await fingerprint(new Uint8Array(der)) : '';
    } finally { clearTimeout(timer); }
  }

  async read(): Promise<Uint8Array | null> {
    if (this.sinceYield >= 1024 * 1024) {
      this.sinceYield = 0;
      await new Promise<void>((resolve) => { setTimeout(resolve, 0); });
    }
    while (true) {
      const value = this.stream.read();
      if (typeof value !== 'number') {
        this.sinceYield += value.byteLength;
        return new Uint8Array(value);
      }
      if (value === 0) return null;
      await this.stream.wait(value === wantWrite);
    }
  }

  async send(data: ArrayBuffer): Promise<void> {
    let offset = 0;
    while (offset < data.byteLength) {
      const rc = this.stream.write(data, offset);
      if (rc > 0) offset += rc;
      else if (rc < 0) await this.stream.wait(rc === wantWrite);
      else throw new Error('连接已结束');
    }
  }

  async close(): Promise<void> { this.stream.close(); }
}
