import { describe, expect, it } from '@ohos/hypium';
import { url, util } from '@kit.ArkTS';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { API, DeviceInfo, FileInfo, Offer, Ticket } from '../../../main/ets/model/Protocol';
import { HttpConnection, HttpWire, decode, encode } from '../../../main/ets/network/HttpConnection';
import { Transfers } from '../../../main/ets/transfer/Transfers';
import { ReceivedFiles, ReceiveStore, FileWriter } from '../../../main/ets/storage/ReceivedFiles';

class MemoryWire implements HttpWire {
  feed: (bytes: Uint8Array) => void = () => {};
  output: string = '';
  listen(data: (part: Uint8Array) => void, end: () => void, error: () => void): void { this.feed = data; }
  async send(data: ArrayBuffer): Promise<void> { this.output += decode(new Uint8Array(data)); }
  async close(): Promise<void> {}
}

class MemoryFile implements FileWriter {
  text: string = '';
  saved: boolean = false;
  discarded: boolean = false;
  write(bytes: Uint8Array): void { this.text += decode(bytes); }
  async finish(isCurrent: () => boolean, hash?: string): Promise<void> {
    if (!isCurrent()) throw new Error('cancelled');
    if (hash) throw new Error('SHA256');
    this.saved = true;
  }
  discard(): void { this.discarded = true; }
}

class Store implements ReceiveStore {
  file: MemoryFile = new MemoryFile();
  full: boolean = false;
  begin(info: FileInfo, sender: string): FileWriter {
    if (this.full) throw new Error('no space');
    return this.file;
  }
}

class Receiver {
  info: DeviceInfo = {alias:'Desktop',port:53317,version:'2.2',deviceType:'desktop',protocol:'https',fingerprint:'AA'};
  file: FileInfo = {id:'one',fileName:'照片.jpg',fileType:'image/jpeg',size:3};
  store = new Store();
  service = new Transfers({key:'',certificate:'',fingerprint:'BB'},this.store,() => this.info,() => {
    if (this.service.view.confirming) this.service.answerReceive(this.accept);
  });
  accept: boolean = true;
  async request(route: string, body: string, fingerprint: string = 'AA'): Promise<string> {
    const wire = new MemoryWire();
    const http = new HttpConnection(wire);
    if (body) wire.feed(encode(body));
    const headers = new Map<string,string>();
    headers.set('content-length',String(encode(body).length));
    await this.service.receive(http,{line:'POST',headers},new url.URL('https://localhost'+API+route),'192.168.1.20',fingerprint);
    return wire.output;
  }
  async prepare(): Promise<string> {
    const files: Record<string,FileInfo> = {};
    files['one'] = this.file;
    const offer: Offer = {info:this.info,files};
    return this.request('prepare-upload',JSON.stringify(offer));
  }
  token(response: string): Ticket { return JSON.parse(response.split('\r\n\r\n')[1]) as Ticket; }
  async upload(ticket: Ticket): Promise<string> {
    return this.request('upload?sessionId='+ticket.sessionId+'&fileId=one&token='+ticket.files['one'],'abc');
  }
}

export default function transferTests() {
  describe('Transfer', () => {
    it('reopen_preserves_completed_files_and_cleans_interrupted_writes',0,async () => {
      const root = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir + '/test-' + util.generateRandomUUID();
      const info: FileInfo = {id:'a',fileName:'../同名.txt',size:3,fileType:'text/plain'};
      const files = new ReceivedFiles(root);
      try {
        for (let i = 0; i < 2; i++) {
          const file = files.begin(info,'LocalSend');
          file.write(encode('abc'));
          await file.finish(() => true,'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
        }
        fs.mkdirSync(root + '/partial-interrupted');
        const records = new ReceivedFiles(root).history();
        expect(records.length).assertEqual(2);
        expect(records[0].name).assertEqual('同名.txt');
        expect(records[0].id === records[1].id).assertFalse();
        expect(fs.readTextSync(root + '/' + records[1].id + '/data')).assertEqual('abc');
        expect(fs.listFileSync(root).length).assertEqual(2);
      } finally { fs.rmdirSync(root); }
    });
    it('chunked_binary_preserves_framing',0,async () => {
      const wire = new MemoryWire();
      const http = new HttpConnection(wire);
      for (const byte of encode('POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1\r\nc\r\n0\r\n\r\n')) {
        wire.feed(new Uint8Array([byte]));
      }
      expect(await http.text(await http.head())).assertEqual('abc');
    });
    it('ambiguous_length_is_rejected_before_writing',0,async () => {
      const wire = new MemoryWire();
      const http = new HttpConnection(wire);
      wire.feed(encode('POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n'));
      let rejected = false;
      try { await http.text(await http.head()); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('chunked_stream_spans_many_tls_record_boundaries',0,async () => {
      const wire = new MemoryWire();
      const http = new HttpConnection(wire);
      const payload = new Uint8Array(16384);
      for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
      for (let chunk = 0; chunk < 4; chunk++) {
        wire.feed(encode('80000\r\n'));
        for (let record = 0; record < 32; record++) wire.feed(payload);
        wire.feed(encode('\r\n'));
      }
      wire.feed(encode('0\r\n\r\n'));
      const headers = new Map<string,string>();
      headers.set('transfer-encoding','chunked');
      let matching = true;
      let offset = 0;
      await http.body({line:'POST',headers},2097152,(bytes: Uint8Array) => {
        for (const byte of bytes) {
          if (byte !== payload[offset % payload.length]) matching = false;
          offset++;
        }
      });
      expect(offset).assertEqual(2097152);
      expect(matching).assertTrue();
    });
    it('cancel_requires_current_session_and_peer',0,async () => {
      const r = new Receiver();
      const ticket = r.token(await r.prepare());
      expect((await r.request('cancel?sessionId='+ticket.sessionId,'','wrong')).startsWith('HTTP/1.1 403')).assertTrue();
      expect(r.service.view.active).assertTrue();
      expect((await r.request('cancel?sessionId='+ticket.sessionId,'')).startsWith('HTTP/1.1 200')).assertTrue();
      expect(r.service.view.active).assertFalse();
      expect((await r.upload(ticket)).startsWith('HTTP/1.1 403')).assertTrue();
    });
    it('one_approved_file_is_saved_once',0,async () => {
      const r = new Receiver();
      const ticket = r.token(await r.prepare());
      expect((await r.upload(ticket)).startsWith('HTTP/1.1 200')).assertTrue();
      expect(r.store.file.text).assertEqual('abc');
      expect(r.store.file.saved).assertTrue();
      expect((await r.upload(ticket)).startsWith('HTTP/1.1 403')).assertTrue();
    });
    it('busy_receiver_rejects_another_offer',0,async () => {
      const r = new Receiver();
      const ticket = r.token(await r.prepare());
      expect((await r.prepare()).startsWith('HTTP/1.1 409')).assertTrue();
      await r.upload(ticket);
    });
    it('denied_offer_leaves_slot_free',0,async () => {
      const r = new Receiver();
      r.accept = false;
      expect((await r.prepare()).startsWith('HTTP/1.1 403')).assertTrue();
      r.accept = true;
      expect((await r.upload(r.token(await r.prepare()))).startsWith('HTTP/1.1 200')).assertTrue();
    });
    it('failed_creation_releases_slot',0,async () => {
      const r = new Receiver();
      r.store.full = true;
      expect((await r.upload(r.token(await r.prepare()))).startsWith('HTTP/1.1 500')).assertTrue();
      r.store.full = false;
      expect((await r.upload(r.token(await r.prepare()))).startsWith('HTTP/1.1 200')).assertTrue();
    });
    it('checksum_failure_discards_partial_file',0,async () => {
      const r = new Receiver();
      r.file.sha256 = 'different';
      expect((await r.upload(r.token(await r.prepare()))).startsWith('HTTP/1.1 422')).assertTrue();
      expect(r.store.file.discarded).assertTrue();
    });
  });
}
