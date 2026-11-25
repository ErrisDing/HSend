import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { picker } from '@kit.CoreFileKit';
import { connection } from '@kit.NetworkKit';
import { DeviceInfo, PORT, Peer } from '../model/Protocol';
import { DeviceIdentity, loadOrCreateIdentity } from '../network/Identity';
import { Discovery } from '../network/Discovery';
import { Transfers } from '../transfer/Transfers';
import { Receipt, ReceivedFiles, SelectedFile, selectFile } from '../storage/ReceivedFiles';

export class AppSession {
  alias: string = 'HSend';
  theme: string = '跟随系统';
  tab: number = 0;
  selected: SelectedFile[] = [];
  status: string = '正在初始化';
  identity?: DeviceIdentity;
  network?: Discovery;
  transfers?: Transfers;
  store?: ReceivedFiles;
  context?: common.UIAbilityContext;
  private prefs?: preferences.Preferences;
  private net?: connection.NetConnection;
  private serial: Promise<void> = Promise.resolve();
  private disposed: boolean = false;
  private listeners: Set<() => void> = new Set();
  private updateTimer: number = -1;

  watch(fn: () => void): void { this.listeners.add(fn); }
  unwatch(fn: () => void): void { this.listeners.delete(fn); }
  notify(): void {
    if (this.updateTimer !== -1) return;
    this.updateTimer = setTimeout(() => {
      this.updateTimer = -1;
      this.listeners.forEach((fn: () => void) => fn());
    },50);
  }

  private info(): DeviceInfo {
    return {alias:this.alias,version:'2.2',fingerprint:this.identity!.fingerprint,deviceType:'mobile',
      deviceModel:'HarmonyOS',port:PORT,protocol:'https',download:false};
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.prefs = await preferences.getPreferences(context,{name:'hsend'});
    this.alias = await this.prefs.get('alias','HSend') as string;
    this.theme = await this.prefs.get('theme','跟随系统') as string;
    this.store = new ReceivedFiles(context.filesDir + '/received');
    this.identity = await loadOrCreateIdentity(context);
    this.transfers = new Transfers(this.identity,this.store,() => this.info(),() => this.notify());
    const net = connection.createNetConnection();
    this.net = net;
    net.on('netAvailable',() => this.resetNetwork());
    net.on('netLost',() => this.resetNetwork());
    net.register((err) => { if (err) this.error(err.message); });
    this.resetNetwork();
  }

  private resetNetwork(): void {
    this.serial = this.serial.then(async () => {
      if (this.disposed || !this.identity || !this.transfers) return;
      const local = this.network;
      if (local) {
        try {
          const handle = connection.getDefaultNetSync();
          const props = await connection.getConnectionProperties(handle);
          if (local.networkId === handle.netId && local.address &&
            props.linkAddresses.some((a: connection.LinkAddress) => a.address.address === local.address)) return;
        } catch (_) {}
        await this.transfers.cancel().catch(() => {});
        await local.stop();
      }
      const network = new Discovery(this.identity,() => this.info(),this.transfers,() => this.notify(),(s: string) => this.error(s));
      this.network = network;
      try { await network.start(); this.status = ''; }
      catch (e) { await network.stop(); this.network = undefined; this.status = '网络未就绪：' + (e as Error).message; }
      this.notify();
    }).catch((e: Error) => this.error(e.message));
  }

  async refresh(): Promise<void> {
    if (!this.network) { this.resetNetwork(); return; }
    await this.network.refresh();
  }

  error(s: string): void { this.status = s; this.notify(); }

  async pick(): Promise<void> {
    if (!this.context) return;
    const uris = await new picker.DocumentViewPicker(this.context).select({maxSelectNumber:100});
    for (const uri of uris) {
      if (!this.selected.some((item: SelectedFile) => item.uri === uri)) this.selected.push(selectFile(uri));
    }
    this.notify();
  }

  async send(peer: Peer): Promise<void> {
    if (!this.transfers) throw new Error('网络尚未就绪');
    await this.transfers.sendFiles(peer,this.selected.slice());
  }

  async settings(name: string, value: string): Promise<void> {
    const text = value.trim();
    if (!text || !this.prefs) return;
    await this.prefs.put(name,text);
    await this.prefs.flush();
    if (name === 'alias') { this.alias = text; await this.refresh(); }
    if (name === 'theme') this.theme = text;
    this.notify();
  }

  async exportFile(record: Receipt): Promise<void> {
    if (this.store && this.context) await this.store.export(this.context,record);
  }

  async stop(): Promise<void> {
    this.disposed = true;
    this.net?.unregister(() => {});
    await this.serial;
    await this.transfers?.cancel().catch(() => {});
    await this.network?.stop();
    this.listeners.clear();
  }
}

export let appSession = new AppSession();
export function newAppSession(): AppSession {
  appSession = new AppSession();
  return appSession;
}
