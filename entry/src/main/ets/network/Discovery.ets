import { socket, connection } from '@kit.NetworkKit';
import { url } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { API, DeviceInfo, GROUP, PORT, Peer } from '../model/Protocol';
import { IncomingTls } from './IncomingTls';
import { listen, Listener } from 'libhsend_tls.so';
import { DeviceIdentity } from './Identity';
import { connectPeer } from './TlsTransport';
import { HttpConnection, decode, encode } from './HttpConnection';
import { Transfers } from '../transfer/Transfers';

export class Discovery {
  devices: Peer[] = [];
  address: string = '';
  networkId: number = -1;
  private udp?: socket.MulticastSocket;
  private listener?: Listener;
  private roots: Set<string> = new Set();
  private probing: Set<string> = new Set();
  private connections: Set<IncomingTls> = new Set();
  private stopped: boolean = false;
  private identity: DeviceIdentity;
  private info: () => DeviceInfo;
  private transfers: Transfers;
  private change: () => void;
  private report: (error: string) => void;

  constructor(identity: DeviceIdentity, info: () => DeviceInfo, transfers: Transfers, change: () => void, report: (error: string) => void) {
    this.identity = identity;
    this.info = info;
    this.transfers = transfers;
    this.change = change;
    this.report = report;
  }

  async start(): Promise<void> {
    try {
      this.listener = listen(this.identity.certificate, this.identity.key, PORT);
      this.acceptLoop(this.listener).catch((err: Error) => { if (!this.stopped) this.report(err.message); });
    }
    catch (err) { throw new Error('HTTPS 监听失败：' + (err as Error).message); }
    const udp = socket.constructMulticastSocketInstance();
    this.udp = udp;
    // addMembership binds the multicast port as well as joining the group.
    try { await udp.addMembership({address:GROUP,family:1,port:PORT}); }
    catch (err) { throw new Error('加入组播失败：' + (err as Error).message); }
    udp.on('message',(msg: socket.SocketMessageInfo) => {
      if (this.stopped || msg.message.byteLength > 16384) return;
      try {
        const info = JSON.parse(decode(new Uint8Array(msg.message))) as DeviceInfo;
        if (!this.valid(info) || this.probing.has(info.fingerprint)) return;
        this.probing.add(info.fingerprint);
        this.register(new Peer(msg.remoteInfo.address,info)).catch((error: Error) => this.report(error.message))
          .finally(() => this.probing.delete(info.fingerprint));
      } catch (_) { /* Other traffic on the group is not a LocalSend announcement. */ }
    });
    await this.refresh();
  }

  async refresh(): Promise<void> {
    if (!this.udp || this.stopped) return;
    const handle = connection.getDefaultNetSync();
    const props = await connection.getConnectionProperties(handle);
    this.networkId = handle.netId;
    const ip = props.linkAddresses.find((a: connection.LinkAddress) => a.address.address.includes('.'));
    this.address = ip?.address.address ?? '';
    const msg = this.info();
    msg.announce = true;
    await this.udp.send({address:{address:GROUP,port:PORT,family:1},data:JSON.stringify(msg)});
    this.change();
  }

  private valid(info: DeviceInfo): boolean {
    return !!info && typeof info.alias === 'string' && typeof info.version === 'string' && info.version.startsWith('2.')
      && typeof info.fingerprint === 'string' && /^[a-f0-9]{64}$/i.test(info.fingerprint)
      && info.fingerprint.toUpperCase() !== this.identity.fingerprint && info.protocol === 'https'
      && Number.isInteger(info.port) && info.port > 0 && info.port <= 65535;
  }

  private see(peer: Peer): void {
    const others = this.devices.filter((p: Peer) => p.info.fingerprint.toUpperCase() !== peer.info.fingerprint.toUpperCase());
    this.devices = others.concat(peer);
    this.change();
  }

  private async register(peer: Peer): Promise<void> {
    const http = await connectPeer(peer,this.identity);
    try {
      if (this.stopped) return;
      if (!this.roots.has(peer.info.fingerprint.toUpperCase())) {
        if (this.roots.size >= 64) throw new Error('附近设备超过接收端容量');
        this.roots.add(peer.info.fingerprint.toUpperCase());
      }
      if (peer.info.announce) {
        const body = encode(JSON.stringify(this.info()));
        await http.request(API+'register',peer.address+':'+peer.info.port,body.length,true);
        await http.write(body);
        const head = await http.head();
        if (Number(head.line.split(' ')[1]) !== 200) throw new Error('设备注册失败');
        await http.text(head);
      }
      this.see(peer);
    } finally { http.close(); }
  }

  private async acceptLoop(listener: Listener): Promise<void> {
    while (!this.stopped) {
      const stream = listener.accept();
      if (!stream) { await listener.wait(false); continue; }
      if (this.connections.size >= 32) { stream.close(); continue; }
      const wire = new IncomingTls(stream);
      this.connections.add(wire);
      this.handle(wire,stream.address).catch((err: Error) => {
        hilog.warn(0x0000,'HSend','Incoming TLS: %{public}s',err.message);
      }).finally(() => { wire.close(); this.connections.delete(wire); });
    }
  }

  private async handle(wire: IncomingTls,address: string): Promise<void> {
    const fp = await wire.authenticate();
    const http = new HttpConnection(wire);
    try {
      const head = await http.head();
      const fields = head.line.split(' ');
      if (fields.length === 3 && fields[0] === 'GET' && fields[1] === API+'info') {
        await http.respond(200,JSON.stringify(this.info()));
        return;
      }
      if (fields[0] !== 'POST' || fields.length !== 3 || !fields[1].startsWith(API)) { await http.respond(404); return; }
      const target = new url.URL('https://localhost'+fields[1]);
      if (target.pathname === API+'register') {
        const info = JSON.parse(await http.text(head)) as DeviceInfo;
        if (!this.valid(info) || (fp && info.fingerprint.toUpperCase() !== fp)) { await http.respond(403); return; }
        if (fp && this.roots.has(fp)) this.see(new Peer(address,info));
        else {
          // Bind discovery hints to a live certificate on the advertised port.
          info.announce = false;
          await this.register(new Peer(address,info));
        }
        await http.respond(200,JSON.stringify(this.info()));
      } else {
        if (!fp || !this.roots.has(fp)) { await http.respond(403); return; }
        await this.transfers.receive(http,head,target,address,fp);
      }
    } catch (error) {
      hilog.warn(0x0000,'HSend','HTTPS request ended: %{public}s',(error as Error).message);
      try { await http.respond(400); } catch (_) {}
    } finally { await http.close(); }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    await this.udp?.close().catch(() => {});
    this.listener?.close();
    this.connections.forEach((wire: IncomingTls) => { wire.close(); });
    this.devices = [];
  }
}
