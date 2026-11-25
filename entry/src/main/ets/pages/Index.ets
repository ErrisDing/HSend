import { appSession } from '../app/AppSession';
import { layoutMode, Peer } from '../model/Protocol';
import { Receipt, SelectedFile } from '../storage/ReceivedFiles';
import { FileProgress, TransferView } from '../transfer/Transfers';
import { formatFileProgress, formatFileSize } from './FileSize';

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State mode: number = 0;
  @State theme: string = '跟随系统';
  @State alias: string = 'HSend';
  @State address: string = '';
  @State online: boolean = false;
  @State info: string = '';
  @State status: string = '';
  @State peers: Peer[] = [];
  @State chosen: SelectedFile[] = [];
  @State receipts: Receipt[] = [];
  @State view: TransferView = new TransferView();
  @State detail: string = '';
  private previous?: TransferView;
  private redraw = (): void => this.sync();
  private sync(): void {
    this.tab = appSession.tab;
    this.theme = appSession.theme;
    this.alias = appSession.alias;
    this.address = appSession.network?.address ?? '';
    this.online = this.address !== '';
    this.info = appSession.identity?.fingerprint ?? '';
    this.status = appSession.status;
    this.peers = appSession.network?.devices.slice() ?? [];
    this.chosen = appSession.selected.slice();
    const v = appSession.transfers?.view;
    if (v) {
      if (v !== this.previous && v.active) this.detail = 'transfer';
      this.previous = v;
      const snapshot = new TransferView();
      snapshot.title=v.title; snapshot.peer=v.peer;
      snapshot.items = v.items.map((p: FileProgress): FileProgress => {
        return {id:p.id,name:p.name,size:p.size,done:p.done};
      });
      snapshot.done=v.done; snapshot.total=v.total; snapshot.confirming=v.confirming; snapshot.active=v.active;
      snapshot.receiving=v.receiving;
      this.view = snapshot;
    }
  }
  aboutToAppear(): void { appSession.watch(this.redraw); this.sync(); }
  aboutToDisappear(): void { appSession.unwatch(this.redraw); }
  private colors(light: string,dark: string,system: Resource): ResourceColor {
    if (this.theme === '浅色') return light;
    if (this.theme === '深色') return dark;
    return system;
  }
  private bg(): ResourceColor { return this.colors('#FFFFFF','#000000',$r('app.color.background')); }
  private ink(): ResourceColor { return this.colors('#181820','#F7F7FA',$r('app.color.ink')); }
  private accent(): ResourceColor { return this.colors('#4343CA','#A3A6FF',$r('app.color.accent')); }
  private surface(): ResourceColor { return this.colors('#F7F7FA','#17171C',$r('app.color.surface')); }
  private run(work: Promise<void>): void { work.catch((e: Error) => appSession.error(e.message)); }
  private history(): void {
    try { this.receipts = appSession.store?.history() ?? []; this.detail='history'; }
    catch (e) { appSession.error((e as Error).message); }
  }
  @Builder
  glyph(icon: Resource, size: number) {
    SymbolGlyph(icon).fontSize(size).fontColor([this.accent()])
  }
  @Builder
  navItem(index: number, label: string, icon: Resource) {
    Button({type:ButtonType.Normal}) {
      Flex({direction:this.mode === 2 ? FlexDirection.Row : FlexDirection.Column,alignItems:ItemAlign.Center,justifyContent:FlexAlign.Center}) {
        this.glyph(icon,22)
        if (this.mode !== 1) { Text(label).fontSize(13).fontColor(this.tab === index ? this.accent() : this.ink()).margin(4) }
      }
    }.borderRadius(14).backgroundColor(this.tab === index ? this.surface() : this.bg())
    .accessibilityText(label).height(52).onClick(() => { appSession.tab=index; this.tab=index; })
  }
  @Builder
  navigation() {
    this.navItem(0,'接收',$r('sys.symbol.wifi'))
    this.navItem(1,'发送',$r('sys.symbol.paperplane'))
    this.navItem(2,'设置',$r('sys.symbol.gearshape'))
  }
  @Builder
  receive() {
    Stack({alignContent:Alignment.TopEnd}) {
      Column({space:12}) {
        Image($r('app.media.hsend_mark'))
          .width(80).height(80).objectFit(ImageFit.Contain).fillColor(this.accent())
          .accessibilityLevel('no')
        Text(this.alias).fontSize(44).maxLines(2).textAlign(TextAlign.Center).fontColor(this.ink())
        Text(this.online ? '#'+this.address.split('.').pop() : '离线').fontColor(this.ink()).fontSize(22)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(20)
      Row({space:8}) {
        Button() { this.glyph($r('sys.symbol.clock'),22) }.onClick(() => this.history()).accessibilityText('接收记录').backgroundColor(this.surface())
        Button() { this.glyph($r('sys.symbol.info_circle'),22) }.onClick(() => { this.detail='info'; }).accessibilityText('连接信息').backgroundColor(this.surface())
      }.padding(16)
    }.width('100%').height('100%')
  }
  @Builder
  send() {
    Scroll() {
      Column({space:12}) {
        Text(this.chosen.length ? '已选文件（' + this.chosen.length + '）' : '选择').fontColor(this.ink()).fontSize(20)
        Button() {
          Row() { this.glyph($r('sys.symbol.plus'),20); Text('文件').fontColor(this.ink()) }
        }.backgroundColor(this.surface()).onClick(() => this.run(appSession.pick()))
        ForEach(this.chosen,(f: SelectedFile) => {
          Row() {
            Column({space:2}) {
              Text(f.info.fileName).fontColor(this.ink())
              Text(formatFileSize(f.info.size)).fontSize(12).fontColor(this.ink())
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button('移除').backgroundColor(this.surface()).fontColor(this.accent()).onClick(() => {
              appSession.selected=appSession.selected.filter((s: SelectedFile) => s.uri !== f.uri); appSession.notify();
            })
          }.width('100%')
        },(f: SelectedFile) => f.info.id)
        Row({space:12}) {
          Text('附近设备').fontSize(20).fontColor(this.ink())
          Button() { this.glyph($r('sys.symbol.arrow_clockwise'),20) }.backgroundColor(this.surface())
            .accessibilityText('刷新').onClick(() => this.run(appSession.refresh()))
        }
        if (!this.peers.length) { Text('暂未发现设备').fontColor(this.ink()) }
        ForEach(this.peers,(peer: Peer) => {
          Button({type:ButtonType.Normal}) {
            Column() {
              Text(peer.info.alias).fontColor(this.ink())
              Text(peer.address).fontSize(12).fontColor(this.ink())
            }.padding(12)
          }.width('100%').borderRadius(12).backgroundColor(this.surface()).onClick(() => this.run(appSession.send(peer)))
        },(p: Peer) => p.info.fingerprint + p.address + p.info.alias)
      }.alignItems(HorizontalAlign.Start).constraintSize({maxWidth:600}).width('100%').padding(16)
    }.width('100%').height('100%').align(Alignment.Top)
  }
  @Builder
  settings() {
    Scroll() {
      Column({space:18}) {
        Text('设置').fontSize(24).fontColor(this.ink())
        Text('外观').fontColor(this.ink())
        Row({space:6}) {
          ForEach(['跟随系统','浅色','深色'],(t: string) => {
            Button(t).fontColor(this.theme === t ? this.accent() : this.ink()).backgroundColor(this.surface())
              .onClick(() => this.run(appSession.settings('theme',t)))
          })
        }
        Text('设备名称').fontColor(this.ink())
        TextInput({text:this.alias}).maxLength(48).fontColor(this.ink()).backgroundColor(this.surface())
          .onSubmit((key: EnterKeyType,event: SubmitEvent) => this.run(appSession.settings('alias',event.text)))
      }.padding(20).width('100%').constraintSize({maxWidth:600})
    }.width('100%').height('100%').align(Alignment.Top)
  }
  @Builder
  details() {
    Scroll() {
      Column({space:14}) {
        if (this.detail === 'transfer') {
          Text(this.view.title).fontSize(24).fontColor(this.ink())
          Text(this.view.peer).fontColor(this.ink())
          if (!this.view.confirming) {
            Progress({value:this.view.done,total:Math.max(1,this.view.total)}).color(this.accent())
            Text(formatFileProgress(this.view.done,this.view.total)).fontColor(this.ink())
          }
          if (this.view.confirming) {
            Row({space:10}) { Button('拒绝').backgroundColor(this.surface()).fontColor(this.ink()).onClick(() => appSession.transfers?.answerReceive(false))
              Button('接收').backgroundColor(this.accent()).fontColor(this.bg()).onClick(() => appSession.transfers?.answerReceive(true)) }
          } else if (this.view.active) {
            Button('取消传输').backgroundColor(this.surface()).fontColor(this.accent()).onClick(() => { if (appSession.transfers) this.run(appSession.transfers.cancel()); })
          } else if (this.view.receiving) {
            Button('已收文件').backgroundColor(this.surface()).fontColor(this.accent()).onClick(() => this.history())
          }
          ForEach(this.view.items,(item: FileProgress) => {
            Text(item.name).fontColor(this.ink())
            if (this.view.confirming) {
              Text(formatFileSize(item.size)).fontSize(12).fontColor(this.ink())
            } else if (this.view.items.length > 1) {
              Text(formatFileProgress(item.done,item.size)).fontSize(12).fontColor(this.ink())
            }
          },(item: FileProgress) => item.id + '/' + item.done)
        } else if (this.detail === 'history') {
          Text('接收记录').fontSize(24).fontColor(this.ink())
          if (!this.receipts.length) { Text('暂无已收文件').fontColor(this.ink()) }
          ForEach(this.receipts,(r: Receipt) => {
            Row() { Text(r.name+' · '+formatFileSize(r.size)).layoutWeight(1).fontColor(this.ink())
              Button('导出').backgroundColor(this.surface()).fontColor(this.accent()).onClick(() => this.run(appSession.exportFile(r))) }
          },(r: Receipt) => r.id)
        } else {
          Text('连接信息').fontSize(24).fontColor(this.ink())
          Text(this.address || '离线').fontColor(this.ink())
          Text(this.info).fontSize(13).fontColor(this.ink())
        }
        if (this.detail !== 'transfer' || !this.view.active) { Button('返回').backgroundColor(this.surface()).fontColor(this.ink()).onClick(() => { this.detail=''; }) }
      }.width('100%').constraintSize({maxWidth:600}).padding(20)
    }.layoutWeight(1)
  }
  build() {
    Column() {
      if (this.status) { Text(this.status).fontSize(13).fontColor(this.ink()).padding(6) }
      if (this.detail) { this.details() }
      else {
        Row() {
          if (this.mode > 0) {
            Column({space:8}) {
              if (this.mode === 2) { Text('HSend').fontSize(24).fontColor(this.ink()).padding(12) }
              this.navigation()
            }.width(this.mode === 2 ? 156 : 72).height('100%').padding(8)
          }
          Column() {
            if (this.tab === 0) { this.receive() }
            else if (this.tab === 1) { this.send() }
            else { this.settings() }
          }.layoutWeight(1).height('100%')
        }.layoutWeight(1)
        if (this.mode === 0) { Row() { this.navigation() }.width('100%').justifyContent(FlexAlign.SpaceAround) }
      }
    }.width('100%').height('100%').backgroundColor(this.bg())
      .onAreaChange((old: Area,area: Area) => { this.mode=layoutMode(Number(area.width)); })
  }
}
