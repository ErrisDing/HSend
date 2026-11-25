import { util, url as urlKit } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { API, DeviceInfo, FileInfo, Offer, Peer, Ticket } from '../model/Protocol';
import { DeviceIdentity } from '../network/Identity';
import { HttpConnection, HttpHead, encode } from '../network/HttpConnection';
import { connectPeer } from '../network/TlsTransport';
import { FileWriter, ReceiveStore, SelectedFile } from '../storage/ReceivedFiles';

export interface FileProgress {
  id: string;
  name: string;
  size: number;
  done: number;
}

export class TransferView {
  title: string = '';
  peer: string = '';
  items: FileProgress[] = [];
  total: number = 0;
  done: number = 0;
  confirming: boolean = false;
  receiving: boolean = false;
  active: boolean = false;
}

class ReceiveSession {
  id: string = util.generateRandomUUID();
  address: string = '';
  fingerprint: string = '';
  offer: Offer;
  tokens: Record<string,string> = {};
  pending: Set<string> = new Set();
  accepted: boolean = false;
  completed: number = 0;
  streams: Set<HttpConnection> = new Set();
  decide: (ok: boolean) => void = () => {};
  timer: number = -1;
  constructor(offer: Offer) { this.offer = offer; }
}

export class Transfers {
  view: TransferView = new TransferView();
  private incoming?: ReceiveSession;
  private outgoing?: Peer;
  private sender?: HttpConnection;
  private sendingId: string = '';
  private epoch: number = 0;
  private identity: DeviceIdentity;
  private files: ReceiveStore;
  private info: () => DeviceInfo;
  private update: () => void;

  constructor(identity: DeviceIdentity,files: ReceiveStore,info: () => DeviceInfo, update: () => void) {
    this.identity = identity;
    this.files = files;
    this.info = info;
    this.update = update;
  }

  private start(title: string,alias: string,files: FileInfo[]): void {
    this.view = new TransferView();
    this.view.active = true;
    this.view.receiving = this.incoming !== undefined;
    this.view.title = title;
    this.view.peer = alias;
    this.view.items = files.map((file: FileInfo): FileProgress => {
      return {id:file.id,name:file.fileName,size:file.size,done:0};
    });
    this.view.total = files.reduce((n: number,file: FileInfo) => n + file.size,0);
    this.update();
  }

  private end(message: string): void {
    this.view.title = message;
    this.view.active = false;
    this.view.confirming = false;
    this.update();
  }

  answerReceive(accept: boolean): void { this.incoming?.decide(accept); }

  private clearIncoming(session: ReceiveSession, message: string): void {
    if (this.incoming !== session) return;
    this.incoming = undefined;
    clearTimeout(session.timer);
    session.decide(false);
    session.streams.forEach((stream: HttpConnection) => stream.close());
    this.end(message);
  }

  private touch(session: ReceiveSession): void {
    clearTimeout(session.timer);
    session.timer = setTimeout(() => this.clearIncoming(session,'接收超时'),120000);
  }

  async receive(http: HttpConnection, head: HttpHead, url: urlKit.URL, address: string, fp: string): Promise<void> {
    if (url.pathname === API + 'prepare-upload') {
      const offer = JSON.parse(await http.text(head)) as Offer;
      if (offer.info?.fingerprint?.toUpperCase() !== fp) { await http.respond(403); return; }
      const ids = Object.keys(offer.files);
      if (!ids.length || ids.some((id: string) => {
        const file = offer.files[id];
        return !file || !id || ['__proto__','prototype','constructor'].includes(id) || file.id !== id
          || typeof file.fileName !== 'string' || !Number.isSafeInteger(file.size) || file.size < 0;
      })) { await http.respond(400); return; }
      if (this.incoming || this.outgoing) { await http.respond(409); return; }
      const session = new ReceiveSession(offer);
      session.address = address;
      session.fingerprint = fp;
      this.incoming = session;
      const decision = new Promise<boolean>((resolve) => { session.decide = resolve; });
      http.onEnd = () => session.decide(false);
      this.start('接收请求',offer.info.alias,ids.map((id: string) => offer.files[id]));
      this.view.confirming = true;
      this.update();
      this.touch(session);
      if (!(await decision)) {
        this.clearIncoming(session,'已拒绝或请求已结束');
        await http.respond(403);
        return;
      }
      this.view.confirming = false;
      this.view.title = '正在接收';
      session.accepted = true;
      this.touch(session);
      for (const id of ids) { session.tokens[id] = util.generateRandomUUID(); session.pending.add(id); }
      const ticket: Ticket = {sessionId:session.id,files:session.tokens};
      try { await http.respond(200,JSON.stringify(ticket)); }
      catch (err) { this.clearIncoming(session,'对端已断开'); throw err as Error; }
      this.update();
      return;
    }
    const sendingTo = this.outgoing;
    if (url.pathname === API + 'cancel' && sendingTo && this.sendingId &&
      url.searchParams.get('sessionId') === this.sendingId &&
      address === sendingTo.address && fp === sendingTo.info.fingerprint.toUpperCase()) {
      this.abortOutgoing('对端已取消接收');
      await http.respond(200);
      return;
    }
    const session = this.incoming;
    if (!session || address !== session.address || fp !== session.fingerprint) { await http.respond(403); return; }
    const requestedId = url.searchParams.get('sessionId');
    if (url.pathname === API + 'cancel' && (requestedId === session.id || (!requestedId && !session.accepted))) {
      this.clearIncoming(session,'对端已取消');
      await http.respond(200);
      return;
    }
    if (url.pathname !== API + 'upload') { await http.respond(404); return; }
    const id = url.searchParams.get('fileId') ?? '';
    if (!session.accepted || url.searchParams.get('sessionId') !== session.id || !session.pending.has(id)
      || url.searchParams.get('token') !== session.tokens[id]) { await http.respond(403); return; }
    session.pending.delete(id);
    const meta = session.offer.files[id];
    session.streams.add(http);
    let file: FileWriter | undefined;
    try {
      const writer = this.files.begin(meta,session.offer.info.alias);
      file = writer;
      const progress = this.view.items.find((item: FileProgress) => item.id === id);
      await http.body(head,meta.size,(part: Uint8Array) => {
        if (this.incoming !== session) throw new Error('已取消');
        writer.write(part);
        if (progress) progress.done += part.length;
        this.view.done += part.length;
        this.touch(session);
        this.update();
      });
      await writer.finish(() => this.incoming === session,meta.sha256);
      await http.respond(200);
      session.streams.delete(http);
      session.completed++;
      if (session.completed === Object.keys(session.offer.files).length) this.clearIncoming(session,'接收完成');
    } catch (err) {
      session.streams.delete(http);
      try { await http.respond((err as Error).message === 'SHA256' ? 422 : 500); }
      finally {
        try { file?.discard(); }
        finally { this.clearIncoming(session,'接收失败：' + (err as Error).message); }
      }
    }
  }

  async sendFiles(peer: Peer,selected: SelectedFile[]): Promise<void> {
    if (this.incoming || this.outgoing || !selected.length) throw new Error('请选择文件并等待当前传输结束');
    this.outgoing = peer;
    const epoch = ++this.epoch;
    const metadata: Record<string,FileInfo> = {};
    for (const item of selected) metadata[item.info.id] = item.info;
    this.start('等待对端接收',peer.info.alias,selected.map((item: SelectedFile) => item.info));
    try {
      const http = await this.openSender(peer,epoch);
      const offer: Offer = {info:this.info(),files:metadata};
      const body = encode(JSON.stringify(offer));
      await http.request(API+'prepare-upload',peer.address+':'+peer.info.port,body.length,true);
      await http.write(body);
      const head = await http.head();
      const code = Number(head.line.split(' ')[1]);
      if (code === 204) { if (epoch === this.epoch) this.end('发送完成'); return; }
      if (code !== 200) throw new Error(code === 403 ? '对端已拒绝' : '对端返回 ' + code);
      const ticket = JSON.parse(await http.text(head)) as Ticket;
      http.close();
      if (epoch !== this.epoch) return;
      if (typeof ticket.sessionId !== 'string' || !ticket.sessionId || !ticket.files) throw new Error('对端返回了无效的接收会话');
      this.sendingId = ticket.sessionId;
      const accepted = selected.filter((f: SelectedFile) => typeof ticket.files[f.info.id] === 'string');
      this.start('正在发送',peer.info.alias,accepted.map((item: SelectedFile) => item.info));
      for (const item of accepted) {
        const progress = this.view.items.find((p: FileProgress) => p.id === item.info.id);
        const stream = await this.openSender(peer,epoch);
        const path = API+'upload?sessionId='+encodeURIComponent(ticket.sessionId)+'&fileId='+encodeURIComponent(item.info.id)+'&token='+encodeURIComponent(ticket.files[item.info.id]);
        await stream.request(path,peer.address+':'+peer.info.port,item.info.size,false);
        const src = fs.openSync(item.uri,fs.OpenMode.READ_ONLY);
        try {
          let left = item.info.size;
          const buffer = new ArrayBuffer(65536);
          while (left > 0) {
            const count = fs.readSync(src.fd,buffer,{length:Math.min(buffer.byteLength,left)});
            if (!count) throw new Error('文件在发送期间发生变化');
            await stream.write(new Uint8Array(buffer,0,count));
            if (this.epoch !== epoch) throw new Error('已取消');
            this.view.done += count;
            if (progress) progress.done += count;
            left -= count;
            this.update();
          }
        } finally { fs.closeSync(src); }
        const response = await stream.head();
        if (Number(response.line.split(' ')[1]) !== 200) throw new Error('对端保存失败：'+response.line);
        stream.close();
      }
      if (epoch === this.epoch) this.end('发送完成');
    } catch (err) {
      if (epoch === this.epoch) {
        const id = this.sendingId;
        this.end((err as Error).message);
        if (id) this.notifyCancel(peer,id).catch(() => {});
      }
    } finally {
      if (epoch === this.epoch) { this.sender?.close(); this.sender = undefined; this.outgoing = undefined; this.sendingId = ''; }
    }
  }

  private async openSender(peer: Peer,epoch: number): Promise<HttpConnection> {
    const stream = await connectPeer(peer,this.identity);
    if (epoch !== this.epoch) { stream.close(); throw new Error('已取消'); }
    this.sender = stream;
    return stream;
  }

  private abortOutgoing(message: string): void {
    this.epoch++;
    this.sender?.close();
    this.sender = undefined;
    this.sendingId = '';
    this.outgoing = undefined;
    this.end(message);
  }

  async cancel(): Promise<void> {
    const session = this.incoming;
    if (session) {
      this.clearIncoming(session,'已取消接收');
      if (session.accepted) await this.notifyCancel(new Peer(session.address,session.offer.info),session.id);
      return;
    }
    const peer = this.outgoing;
    if (!peer) return;
    const id = this.sendingId;
    this.abortOutgoing('已取消发送');
    if (id) await this.notifyCancel(peer,id);
  }

  private async notifyCancel(peer: Peer,id: string): Promise<void> {
    const http = await connectPeer(peer,this.identity);
    try { await http.request(API+'cancel?sessionId='+encodeURIComponent(id),peer.address+':'+peer.info.port,0,false); await http.head(); }
    finally { http.close(); }
  }
}
