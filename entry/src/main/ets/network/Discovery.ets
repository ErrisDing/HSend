import { socket, connection } from '@kit.NetworkKit';
import { url } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { API, DeviceInfo, GROUP, PORT, Peer } from '../model/Protocol';
import { DeviceIdentity, peerFingerprint } from './Identity';
import { connectPeer } from './TlsTransport';
import { HttpConnection, decode, encode } from './HttpConnection';
import { Transfers } from '../transfer/Transfers';

export class Discovery {
  devices: Peer[] = [];
  address: string = '';
  networkId: number = -1;
  private udp?: socket.MulticastSocket;
  private listener?: socket.TLSSocketServer;
  private roots: Map<string,string> = new Map();
  private probing: Set<string> = new Set();
  private updating: Promise<void> = Promise.resolve();
  private revision: number = 0;
  private loaded: number = -1;
  private connections: number = 0;
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
    this.transfers.onIdle = () => { this.updateListener().catch((error: Error) => this.report(error.message)); };
  }

  async start(): Promise<void> {
    try { await this.updateListener(); }
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
    let certificate = '';
    const http = await connectPeer(peer,this.identity,(value: string) => { certificate = value; });
    try {
      if (this.stopped) return;
      if (!this.roots.has(peer.info.fingerprint.toUpperCase())) {
        if (this.roots.size >= 64) throw new Error('附近设备超过接收端容量');
        this.roots.set(peer.info.fingerprint.toUpperCase(),certificate);
        this.revision++;
      }
      await this.updateListener();
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

  // Network Kit validates incoming client certificates against the CA list
  // supplied at listen time. Only add certificates pinned on a live connection.
  private updateListener(): Promise<void> {
    const work = this.updating.then(async () => {
      if (this.stopped || this.loaded === this.revision || this.connections || this.transfers.view.active) return;
      if (this.listener) {
        await this.listener.close();
        this.listener = undefined;
        this.loaded = -1;
      }
      const revision = this.revision;
      const ca = Array.from(this.roots.values());
      const discoveryOnly = ca.length === 0;
      const server = await this.listen(ca);
      if (this.stopped) { await server.close(); return; }
      this.listener = server;
      server.on('error',(error) => {
        hilog.warn(0x0000,'HSend','TLS socket event: %{public}s',JSON.stringify(error));
      });
      hilog.info(0x0000,'HSend','HTTPS listener ready, peer certificates: %{public}d',ca.length);
      server.on('connect',(wire: socket.TLSSocketConnection) => {
        this.connections++;
        this.handle(wire,discoveryOnly).catch((error: Error) => this.report(error.message)).finally(() => {
          this.connections--;
          this.updateListener().catch((error: Error) => this.report(error.message));
        });
      });
      this.loaded = revision;
    });
    this.updating = work.catch(() => {});
    return work;
  }

  private async listen(ca: string[]): Promise<socket.TLSSocketServer> {
    // Network Kit can report success with an ephemeral port while the old
    // listener is still shutting down. Peers always reconnect to PORT.
    for (let attempt = 0; attempt < 12 && !this.stopped; attempt++) {
      const server = socket.constructTLSSocketServerInstance();
      await server.listen({address:{address:'0.0.0.0',port:PORT,family:1},secureOptions:{
        key:this.identity.key,cert:this.identity.certificate,ca:ca.length ? ca : undefined,
        isBidirectionalAuthentication:ca.length > 0
      },ALPNProtocols:['http/1.1']});
      const address = await server.getLocalAddress();
      if (address.port === PORT) return server;
      hilog.warn(0x0000,'HSend','Waiting for port 53317, assigned %{public}d',address.port);
      await server.close();
      await new Promise<void>((resolve) => { setTimeout(resolve,250); });
    }
    throw new Error('无法绑定局域网端口 53317');
  }

  private async handle(wire: socket.TLSSocketConnection,discoveryOnly: boolean): Promise<void> {
    const http = HttpConnection.fromSocket(wire);
    try {
      const address = (await wire.getRemoteAddress()).address;
      const head = await http.head();
      const fields = head.line.split(' ');
      if (fields.length === 3 && fields[0] === 'GET' && fields[1] === API+'info') {
        await http.respond(200,JSON.stringify(this.info()));
        return;
      }
      if (fields[0] !== 'POST' || fields.length !== 3 || !fields[1].startsWith(API)) { await http.respond(404); return; }
      const target = new url.URL('https://localhost'+fields[1]);
      if (discoveryOnly) {
        // An already-running peer may answer our first announcement with HTTPS
        // register rather than UDP. Treat this as a discovery hint only. Bind
        // it to a certificate on a reverse TLS connection to the source IP.
        if (target.pathname !== API+'register') { await http.respond(403); return; }
        const hint = JSON.parse(await http.text(head)) as DeviceInfo;
        if (!this.valid(hint)) { await http.respond(400); return; }
        hint.announce = false;
        await this.register(new Peer(address,hint));
        await http.respond(200,JSON.stringify(this.info()));
        return;
      }
      const fp = await peerFingerprint(await wire.getRemoteCertificate());
      if (!this.roots.has(fp)) { await http.respond(403); return; }
      if (target.pathname === API+'register') {
        const info = JSON.parse(await http.text(head)) as DeviceInfo;
        if (!this.valid(info) || info.fingerprint.toUpperCase() !== fp) { await http.respond(403); return; }
        this.see(new Peer(address,info));
        await http.respond(200,JSON.stringify(this.info()));
      } else {
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
    await this.updating;
    await this.listener?.close().catch(() => {});
    this.devices = [];
  }
}
